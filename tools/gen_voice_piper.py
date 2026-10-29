"""Озвучка реплик «Ночной смены»: piper + профили персонажей.

У каждого персонажа свой голосовой профиль: модель piper, темп (`length_scale`),
сдвиг питча без изменения длительности и необязательный эффект («плёнка»,
«телефон»). Профили заданы в `PROFILES` по имени спикера из `voice_manifest.json`.

Почему piper, а не SAPI: `SAPI.SpFileStream` в песочнице DSH падает
(`0x80045040`, `0x80045002` без формата), `System.Speech.SelectVoice` отвергается,
WinRT `SpeechSynthesizer.AllVoices` — «Internal Speech Error». piper работает
полностью офлайн из ONNX-весов и не требует аудиоустройства.

Голоса (`ru/ru_RU`, medium): irina, denis, dmitri, ruslan — четыре модели,
шесть говорящих персонажей разведены голосом + темпом + питчем + эффектом.

Использование:
    python tools/gen_voice_piper.py --fetch        # докачать недостающие модели
    python tools/gen_voice_piper.py --dry-run      # план: сколько файлов на профиль
    python tools/gen_voice_piper.py --force        # перегенерировать всё
    python tools/gen_voice_piper.py --only mila --force
    python tools/gen_voice_piper.py --verify       # длины/пик/RMS по профилям
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import wave
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts" / "dialogue" / "data" / "voice_manifest.json"
OUT_DIR = ROOT / "assets" / "audio" / "voice"
PIPER = ROOT / "tools" / "piper" / "piper" / "piper.exe"
VOICE_DIR = ROOT / "tools" / "piper" / "voices"

TARGET_RATE = 44100
HEAD_SIL_MS = 60
TAIL_SIL_MS = 120
SILENCE_DBFS = -50.0
PEAK_DBFS = -1.0
TAPE_NOISE_DB = -38.0

VOICE_MODELS = {
    "irina": "ru_RU-irina-medium",
    "denis": "ru_RU-denis-medium",
    "dmitri": "ru_RU-dmitri-medium",
    "ruslan": "ru_RU-ruslan-medium",
}
VOICES = {name: VOICE_DIR / f"{stem}.onnx" for name, stem in VOICE_MODELS.items()}
HF_URL = (
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
    "ru/ru_RU/{name}/medium/{stem}{suffix}"
)


@dataclass(frozen=True)
class Profile:
    """Голосовой профиль персонажа."""

    voice: str
    rate: float           # 1.0 = обычный темп piper, >1 быстрее, <1 медленнее
    pitch: float          # 1.0 = без сдвига, 0.92 = ниже примерно на 1.4 полутона
    effect: str = "none"  # "none" | "tape" | "phone"
    gain_db: float = 0.0  # добавочная громкость после нормализации

    @property
    def length_scale(self) -> float:
        return 1.0 / self.rate

    @property
    def key(self) -> str:
        return (f"{self.voice} rate={self.rate:.2f} pitch={self.pitch:.2f} "
                f"fx={self.effect} gain={self.gain_db:+.1f}dB")


# Карта персонаж -> профиль. Имена спикеров берутся из voice_manifest.json.
PROFILES = {
    # Мила — молодая женщина, ровный тон.
    "Мила": Profile("irina", 1.00, 1.00, "none"),
    # Галя — женщина постарше, чуть медленнее и ниже.
    "Галя": Profile("irina", 0.94, 0.92, "none"),
    # Плёнка — голос с диктофона: узкая полоса, шум, дропауты.
    "Плёнка": Profile("irina", 0.98, 0.99, "tape"),
    # Запись — тот же диктофон, одна реплика в amb_radio.
    "Запись": Profile("irina", 0.98, 0.99, "tape"),
    # Костя — молодой парень, быстрее и выше.
    "Костя": Profile("denis", 1.04, 1.03, "none"),
    # Прораб — мужчина 50+, третий голос, медленнее и ниже.
    "Прораб": Profile("ruslan", 0.92, 0.95, "none"),
    # Тимур — охранник, четвёртый голос.
    "Тимур": Profile("dmitri", 0.97, 0.97, "none"),
    # Голос в трубке — телефон: полоса 300–3000 Гц, питч ниже, −3 дБ.
    "Голос в трубке": Profile("dmitri", 0.95, 0.90, "phone", -3.0),
    # Проверяющий (t37) — сухой официальный тон: тот же ruslan, но ровнее и выше
    # Прораба, чтобы их не путать.
    "Проверяющий": Profile("ruslan", 1.00, 1.03, "none"),
    # Нил — игрок, нейтральный мужской голос (тот же, что был до t29).
    "Нил": Profile("denis", 1.00, 1.00, "none"),
}
DEFAULT_PROFILE = Profile("denis", 1.00, 1.00, "none")


# --- WAV I/O ----------------------------------------------------------------


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            raise ValueError(f"unexpected wav layout in {path.name}")
        rate = wf.getframerate()
        raw = wf.readframes(wf.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0, rate


def write_wav(path: Path, samples: np.ndarray, rate: int) -> None:
    data = np.clip(samples, -1.0, 1.0)
    ints = np.round(data * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(ints.tobytes())


# --- Базовые операции -------------------------------------------------------


def trim_and_normalise(samples: np.ndarray, rate: int) -> np.ndarray:
    sil = 10.0 ** (SILENCE_DBFS / 20.0)
    loud = np.nonzero(np.abs(samples) >= sil)[0]
    if loud.size == 0:
        raise ValueError("only silence")
    first, last = int(loud[0]), int(loud[-1])
    head = int(rate * HEAD_SIL_MS / 1000)
    tail = int(rate * TAIL_SIL_MS / 1000)
    start = max(0, first - head)
    end = min(samples.size, last + tail)
    return normalise_peak(samples[start:end])


def resample_linear(samples: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate:
        return samples
    factor = dst_rate / float(src_rate)
    out_len = int(round(samples.size * factor))
    if out_len <= 0:
        return samples
    src_idx = np.arange(out_len, dtype=np.float64) / factor
    return np.interp(src_idx, np.arange(samples.size, dtype=np.float64), samples).astype(np.float32)


def normalise_peak(samples: np.ndarray, dbfs: float = PEAK_DBFS) -> np.ndarray:
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    if peak <= 1e-9:
        return samples
    return (samples * ((10.0 ** (dbfs / 20.0)) / peak)).astype(np.float32)


def limit_peak(samples: np.ndarray, dbfs: float = PEAK_DBFS) -> np.ndarray:
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    limit = 10.0 ** (dbfs / 20.0)
    if peak > limit and peak > 1e-9:
        return (samples * (limit / peak)).astype(np.float32)
    return samples


def db_to_linear(dbfs: float) -> float:
    return 10.0 ** (dbfs / 20.0)


# --- Питч без изменения длительности ---------------------------------------


def time_stretch(samples: np.ndarray, speed: float, frame: int = 1024, overlap: int = 4) -> np.ndarray:
    """Растяжение по времени без изменения питча (OLA, 75 % перекрытие).

    speed > 1 — быстрее (короче), speed < 1 — медленнее (длиннее).
    """
    speed = float(speed)
    if samples.size == 0 or abs(speed - 1.0) < 1e-4:
        return samples
    win = np.hanning(frame).astype(np.float32)
    hop_s = max(1, frame // overlap)
    hop_a = max(1, int(round(hop_s * speed)))
    n = samples.size
    out = np.zeros(int(round(n / speed)) + frame, dtype=np.float32)
    wsum = np.zeros_like(out)
    pa = ps = 0
    while pa + frame <= n:
        out[ps:ps + frame] += samples[pa:pa + frame] * win
        wsum[ps:ps + frame] += win
        pa += hop_a
        ps += hop_s
    if pa < n:
        rem = min(n - pa, out.size - ps)
        if rem > 0:
            out[ps:ps + rem] += samples[pa:pa + rem] * win[:rem]
            wsum[ps:ps + rem] += win[:rem]
            ps += rem
    # Hann окно на краях близко к нулю: делим на wsum с полом, иначе деление на
    # почти ноль выжигает одиночный сэмпл в клик (пик вырастал в 5 раз).
    out = out / np.maximum(wsum, 1e-2)
    out = np.clip(out, -1.0, 1.0)
    body = out[:max(1, ps)]
    fade = min(body.size, int(0.005 * 44100))
    if fade > 1:
        ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
        body[:fade] *= ramp
        body[-fade:] *= ramp[::-1]
    return body.astype(np.float32)


def pitch_shift(samples: np.ndarray, rate: int, factor: float) -> np.ndarray:
    """Сдвиг питча на factor (0.9 = ниже) с сохранением длительности.

    Шаги: ресемплинг меняет питч и длительность -> OLA возвращает длину.
    """
    factor = float(factor)
    if samples.size < 64 or abs(factor - 1.0) < 1e-4:
        return samples
    n = samples.size
    target = max(64, int(round(n / factor)))
    idx = np.arange(target, dtype=np.float64) * (n / float(target))
    src = np.arange(n, dtype=np.float64)
    resampled = np.interp(idx, src, samples).astype(np.float32)
    stretched = time_stretch(resampled, 1.0 / factor)
    if stretched.size < n:
        stretched = np.pad(stretched, (0, n - stretched.size))
    return stretched[:n].astype(np.float32)


# --- Эффекты ----------------------------------------------------------------


def bandpass(samples: np.ndarray, rate: int, low: float, high: float, edge: float = 150.0) -> np.ndarray:
    """Полосовой фильтр через FFT с мягкими краями (без scipy)."""
    n = samples.size
    if n < 8:
        return samples
    freqs = np.fft.rfftfreq(n, d=1.0 / rate)
    mask = np.ones_like(freqs)
    if low > 0:
        mask *= np.clip((freqs - (low - edge)) / edge, 0.0, 1.0)
    if high > 0:
        mask *= np.clip(((high + edge) - freqs) / edge, 0.0, 1.0)
    spec = np.fft.rfft(samples) * mask
    return np.fft.irfft(spec, n=n).astype(np.float32)


def add_dropouts(samples: np.ndarray, rate: int, seed: int) -> np.ndarray:
    """Редкие просадки амплитуды — как у изношенной плёнки."""
    n = samples.size
    if n < rate // 2:
        return samples
    rng = np.random.default_rng(seed)
    count = max(1, int(round((n / float(rate)) / 2.5)))
    out = samples.copy()
    for _ in range(count):
        length = int(rate * rng.uniform(0.025, 0.055))
        if length < 16 or n < length + 8:
            continue
        start = int(rng.integers(0, n - length))
        depth = float(rng.uniform(0.15, 0.35))
        fade = min(max(1, int(rate * 0.006)), length // 2)
        env = np.full(length, depth, dtype=np.float32)
        if fade > 0:
            env[:fade] = np.linspace(1.0, depth, fade, dtype=np.float32)
            env[-fade:] = np.linspace(depth, 1.0, fade, dtype=np.float32)
        out[start:start + length] *= env
    return out


def add_noise(samples: np.ndarray, seed: int, rms_dbfs: float = TAPE_NOISE_DB) -> np.ndarray:
    rng = np.random.default_rng(seed ^ 0x5A5A5A5A)
    noise = rng.normal(0.0, db_to_linear(rms_dbfs), samples.size).astype(np.float32)
    return (samples + noise).astype(np.float32)


def apply_effect(samples: np.ndarray, rate: int, effect: str, seed: int) -> np.ndarray:
    if effect == "tape":
        out = bandpass(samples, rate, 300.0, 3400.0, edge=150.0)
        out = add_dropouts(out, rate, seed)
        out = normalise_peak(out)
        out = add_noise(out, seed)
        return limit_peak(out)
    if effect == "phone":
        # lowpass 3400 + телефонная полоса 300–3000 -> итог 300–3000 Гц
        out = bandpass(samples, rate, 300.0, 3000.0, edge=200.0)
        return normalise_peak(out)
    return normalise_peak(samples)


# --- Синтез -----------------------------------------------------------------


def synth_raw(text: str, voice_path: Path, length_scale: float) -> tuple[np.ndarray, int]:
    with tempfile.TemporaryDirectory(prefix="piper_") as tmp:
        raw = Path(tmp) / "raw.wav"
        cmd = [
            str(PIPER),
            "--model", str(voice_path),
            "--length_scale", f"{length_scale:.4f}",
            "--output_file", str(raw),
        ]
        proc = subprocess.run(
            cmd,
            input=text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0 or not raw.exists():
            raise RuntimeError(
                f"piper failed ({proc.returncode}): "
                + proc.stderr.decode("utf-8", "replace")[-400:]
            )
        return read_wav(raw)


def render(text: str, profile: Profile, dest: Path, seed: int) -> float:
    samples, rate = synth_raw(text, VOICES[profile.voice], profile.length_scale)
    body = trim_and_normalise(samples, rate)
    body = resample_linear(body, rate, TARGET_RATE)
    body = pitch_shift(body, TARGET_RATE, profile.pitch)
    body = apply_effect(body, TARGET_RATE, profile.effect, seed)
    if profile.gain_db:
        body = (body * db_to_linear(profile.gain_db)).astype(np.float32)
    body = limit_peak(body)
    write_wav(dest, body, TARGET_RATE)
    return body.size / TARGET_RATE


# --- Модели голосов ---------------------------------------------------------


def missing_voices(profiles) -> list[str]:
    needed = {p.voice for p in profiles}

    def ok(name: str) -> bool:
        model = VOICES[name]
        config = model.with_suffix(".onnx.json")
        return model.exists() and model.stat().st_size > 0 and config.exists()

    return sorted(name for name in needed if not ok(name))


def fetch_voice(name: str) -> None:
    VOICE_DIR.mkdir(parents=True, exist_ok=True)
    stem = VOICE_MODELS[name]
    for suffix in (".onnx", ".onnx.json"):
        dest = VOICE_DIR / f"{stem}{suffix}"
        if dest.exists() and dest.stat().st_size > 0:
            print(f"  [skip] {dest.name} уже есть")
            continue
        url = HF_URL.format(name=name, stem=stem, suffix=suffix)
        request = urllib.request.Request(url, headers={"User-Agent": "night-shift-voice/1.0"})
        tmp = dest.with_suffix(dest.suffix + ".part")
        print(f"  загрузка {dest.name} …")
        with urllib.request.urlopen(request, timeout=300) as response, tmp.open("wb") as fh:
            shutil.copyfileobj(response, fh)
        tmp.replace(dest)
        print(f"  ok {dest.name}: {dest.stat().st_size / 1048576:.1f} МБ")


# --- Режимы -----------------------------------------------------------------


def build_plan(only: str):
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    total_units = sum(1 for dlg in data.values() for _ in dlg)
    plan = []
    for dialogue_id, nodes in data.items():
        if only and dialogue_id != only:
            continue
        for node_id, entry in nodes.items():
            if not isinstance(entry, dict):
                continue
            text = str(entry.get("text") or "")
            if not any(ch.isalpha() for ch in text):
                continue
            speaker = str(entry.get("speaker") or "")
            profile = PROFILES.get(speaker, DEFAULT_PROFILE)
            plan.append((dialogue_id, node_id, speaker, text,
                         OUT_DIR / f"{dialogue_id}_{node_id}.wav", profile))
    return data, total_units, plan


def print_profiles(plan) -> None:
    groups: dict[str, list] = {}
    for item in plan:
        groups.setdefault(item[2] or "(без спикера)", []).append(item)
    print(f"[voice] профилей персонажей: {len(groups)}, уникальных (голос/питч/эффект): "
          f"{len({item[5].key for item in plan})}")
    for speaker in sorted(groups):
        profile = groups[speaker][0][5]
        print(f"  {speaker:<16} {len(groups[speaker]):>3} файлов  <- {profile.key}")


def verify(plan) -> int:
    rows = []
    for dialogue_id, node_id, speaker, text, dest, profile in plan:
        if not dest.exists():
            rows.append((speaker, profile, dest.name, None, None, None))
            continue
        samples, rate = read_wav(dest)
        duration = samples.size / float(rate)
        peak = float(np.max(np.abs(samples))) if samples.size else 0.0
        rms = float(np.sqrt(np.mean(samples.astype(np.float64) ** 2))) if samples.size else 0.0
        rows.append((speaker, profile, dest.name, duration,
                     20.0 * np.log10(peak) if peak > 0 else -120.0, rms * 32768.0))

    failures = []
    groups: dict[str, list] = {}
    for row in rows:
        groups.setdefault(row[0] or "(без спикера)", []).append(row)

    print(f"{'персонаж':<16} {'файлов':>6} {'мин.длит':>9} {'пик, dB':>14} {'мин.RMS':>8}  профиль")
    for speaker in sorted(groups):
        items = groups[speaker]
        durations = [r[3] for r in items if r[3] is not None]
        peaks = [r[4] for r in items if r[4] is not None]
        rmss = [r[5] for r in items if r[5] is not None]
        missing = sum(1 for r in items if r[3] is None)
        dur_txt = f"{min(durations):.2f}s" if durations else "—"
        peak_txt = f"{min(peaks):+.1f}…{max(peaks):+.1f}" if peaks else "—"
        rms_txt = f"{min(rmss):.0f}" if rmss else "—"
        print(f"{speaker:<16} {len(items):>6} {dur_txt:>9} {peak_txt:>14} {rms_txt:>8}  "
              f"{items[0][1].key}")
        if missing:
            failures.append(f"{speaker}: нет {missing} файл(ов)")
        for r in items:
            if r[3] is None:
                continue
            if r[3] < 0.5:
                failures.append(f"{r[2]}: длительность {r[3]:.2f} с < 0.5 с")
            if r[4] > -1.0 or r[4] < -6.0:
                failures.append(f"{r[2]}: пик {r[4]:+.2f} dBFS вне −1…−6")
            if r[5] < 1000.0:
                failures.append(f"{r[2]}: RMS {r[5]:.0f} < 1000 (тихо)")

    print(f"\n[voice] проверено файлов: {len(rows)}; нарушений: {len(failures)}")
    for line in failures[:25]:
        print("  " + line)
    if len(failures) > 25:
        print(f"  … ещё {len(failures) - 25}")
    return 1 if failures else 0


def main() -> int:
    args = sys.argv[1:]
    force = "--force" in args
    dry = "--dry-run" in args
    do_fetch = "--fetch" in args
    do_verify = "--verify" in args
    only = ""
    if "--only" in args:
        index = args.index("--only")
        if index + 1 < len(args):
            only = args[index + 1]

    if not PIPER.exists():
        print(f"piper not found: {PIPER} (run tools/fetch_piper.py)")
        return 2

    _, total_units, plan = build_plan(only)
    needed = [item[5] for item in plan]
    missing = missing_voices(needed)

    if do_fetch:
        if not missing:
            print("[voice] все модели на месте")
        for name in missing:
            print(f"[voice] качаю голос {name}")
            fetch_voice(name)
        missing = missing_voices(needed)

    print(f"[voice] манифест: диалогов {len({p[0] for p in plan})}, узлов к озвучке {len(plan)} "
          f"(всего в манифесте {total_units})")

    if dry:
        print_profiles(plan)
        already = sum(1 for item in plan if item[4].exists())
        print(f"[voice] на диске уже есть: {already}; будет сгенерировано: {len(plan) - already}")
        if missing:
            print(f"[voice] нет моделей: {', '.join(missing)} "
                  f"(запусти с --fetch, чтобы докачать)")
        print("[voice] dry-run, ничего не записано")
        return 0

    if missing:
        print(f"[voice] нет моделей: {', '.join(missing)}")
        print("        запусти: python tools/gen_voice_piper.py --fetch")
        return 2

    if do_verify:
        return verify(plan)

    created = failed = skipped = 0
    total_sec = 0.0
    for dialogue_id, node_id, speaker, text, dest, profile in plan:
        if dest.exists() and not force:
            skipped += 1
            continue
        seed = zlib.crc32(dest.name.encode("utf-8"))
        try:
            seconds = render(text, profile, dest, seed)
            created += 1
            total_sec += seconds
            print(f"  ok {dest.name} {seconds:5.2f}s {speaker:<16} {profile.key}")
        except Exception as exc:  # noqa: BLE001 - one bad line must not kill the batch
            failed += 1
            print(f"  FAIL {dest.name}: {exc}")

    on_disk = len(list(OUT_DIR.glob("*.wav")))
    print(
        f"\n[voice] готово: создано {created}, пропущено {skipped}, ошибок {failed}; "
        f"на диске {on_disk} из {len(plan)} ожидаемых; "
        f"суммарно {total_sec / 60:.1f} мин речи"
    )
    print_profiles(plan)
    return 1 if failed else 0


def _setup_streams() -> None:
    """UTF-8 в консоль/лог: имена персонажей и «…»/«—» не должны падать на cp1251."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


if __name__ == "__main__":
    _setup_streams()
    try:
        _code = main()
    except BrokenPipeError:
        # `python ... | Select-Object -First N` закрывает трубу: это не ошибка.
        _code = 0
    except KeyboardInterrupt:
        _code = 130
    sys.exit(_code)
