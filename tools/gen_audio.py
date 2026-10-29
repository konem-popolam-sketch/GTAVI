#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генератор синтезированных аудиоассетов «Ночной смены».

Никакой сети и внешних сэмплов: всё считается numpy и пишется в
assets/audio/{ambience,sfx,music} как WAV 44.1 кГц, 16 бит, PCM.

Требования контракта (docs/PHASE2.md, задача t12) и правки t28 (мягкий дождь):
  * 44.1 кГц, 16 бит, mono/stereo;
  * пик не выше −1 dBFS, у дождя — не выше −6 dBFS (дождь — фон);
  * дождь мягкий: полоса 200-2500 Гц, спад −6 дБ/окт выше 2 кГц, гул 40-120 Гц,
    редкие «плюхи» с длинным затуханием, rain_light и rain_heavy равны по RMS ±1 дБ;
  * петли (дождь, гул, вода, музыка) склеены кроссфейдом cos/sin (у дождя 0.5 с),
    без щелчка и без провала громкости на стыке (у дождя < 1 дБ);
  * ноль клиппинга, ноль DC-смещения.

Запуск:
    python tools/gen_audio.py                # сгенерировать всё + отчёт
    python tools/gen_audio.py --verify       # только проверить готовые файлы
    python tools/gen_audio.py --report-only  # пересобрать отчёт без синтеза

Отчёт: tools/t12_audio_report.txt (таблица: файл, длительность, каналы,
пик, RMS, метрика стыка петли).
"""

import argparse
import math
import os
import sys
import wave

import numpy as np

SR = 44100
PEAK_LIMIT_DBFS = -1.0
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO_ROOT = os.path.join(PROJECT_ROOT, "assets", "audio")
REPORT_PATH = os.path.join(PROJECT_ROOT, "tools", "t12_audio_report.txt")
MIN_FILES = 12


# ---------------------------------------------------------------------------
# Базовые утилиты
# ---------------------------------------------------------------------------


def time_axis(n, sr=SR):
    return np.arange(n, dtype=np.float64) / float(sr)


def peak_dbfs(data):
    if data.size == 0:
        return -120.0
    return 20.0 * math.log10(max(float(np.max(np.abs(data))), 1e-9))


def rms_dbfs(data):
    if data.size == 0:
        return -120.0
    rms = float(np.sqrt(np.mean(np.square(data))))
    return 20.0 * math.log10(max(rms, 1e-9))


def rms_linear(data):
    if data.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(data))))


def normalize(data, peak_db=PEAK_LIMIT_DBFS):
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if peak <= 1e-12:
        return data
    target = 10.0 ** (peak_db / 20.0)
    return data * (target / peak)


def band_gain(freqs, low, high, order=2.0):
    """Мягкая полосовая маска для FFT-фильтрации (без scipy)."""
    gain = np.ones_like(freqs, dtype=np.float64)
    if low > 0.0:
        gain = gain / np.sqrt(1.0 + (low / np.maximum(freqs, 1e-6)) ** (2.0 * order))
    if high > 0.0:
        gain = gain / np.sqrt(1.0 + (freqs / high) ** (2.0 * order))
    return gain


def fft_filter(data, gain_fn, sr=SR):
    """Нулевая фаза: фильтрация через спектр (быстро и без IIR-циклов)."""
    data = np.asarray(data, dtype=np.float64)
    n = data.shape[0]
    spectrum = np.fft.rfft(data, axis=0)
    freqs = np.fft.rfftfreq(n, 1.0 / float(sr))
    gain = np.asarray(gain_fn(freqs), dtype=np.float64)
    if data.ndim == 2:
        gain = gain[:, None]
    return np.fft.irfft(spectrum * gain, n=n, axis=0)


def crossfade_loop(data, fade_seconds, sr=SR, equal_power=True):
    """Склейка петли: хвост длины fade плавно подмешивается в начало.

    На выходе ровно len(data) - fade*sr отсчётов, и переход
    out[-1] -> out[0] остаётся непрерывным (out[0] = data[len]).

    equal_power=True — cos/sin-окно: уровень постоянен для *некоррелированных*
    сигналов (шум дождя, гул). Для музыки хвост и начало — это одна и та же
    аранжировка (период 16 тактов), сигналы коррелированы, и cos/sin дал бы
    всплеск до +3 дБ в середине склейки; поэтому музыка склеивается линейным
    окном (equal_power=False): w1 + w2 = 1, амплитуда не гуляет.
    """
    data = np.asarray(data, dtype=np.float64)
    fade = int(round(fade_seconds * sr))
    fade = max(1, min(fade, data.shape[0] // 3))
    total = data.shape[0]
    length = total - fade
    out = data[:length].copy()
    if equal_power:
        theta = np.linspace(0.0, math.pi / 2.0, fade)
        if out.ndim == 2:
            theta = theta[:, None]
        weight_out = np.cos(theta)
        weight_in = np.sin(theta)
    else:
        ramp = np.linspace(0.0, 1.0, fade)
        if out.ndim == 2:
            ramp = ramp[:, None]
        weight_out = 1.0 - ramp
        weight_in = ramp
    out[:fade] = data[length:length + fade] * weight_out + data[:fade] * weight_in
    return out


def add_at(buffer, start_seconds, signal, gain=1.0, sr=SR):
    start = int(round(start_seconds * sr))
    if start >= buffer.shape[0]:
        return
    end = min(buffer.shape[0], start + int(signal.shape[0]))
    if end <= start:
        return
    buffer[start:end] += signal[: end - start] * gain


def fade_edges(data, seconds=0.002, sr=SR):
    data = np.asarray(data, dtype=np.float64).copy()
    n = int(round(seconds * sr))
    n = max(0, min(n, data.shape[0] // 4))
    if n < 2:
        return data
    ramp = np.linspace(0.0, 1.0, n)
    if data.ndim == 2:
        ramp = ramp[:, None]
    data[:n] *= ramp
    data[-n:] *= ramp[::-1]
    return data


def write_wav(path, data, sr=SR, peak_db=PEAK_LIMIT_DBFS, edge_fade=0.003, loop=False):
    """Пишет PCM16 WAV. Возвращает словарь метрик для отчёта."""
    data = np.asarray(data, dtype=np.float64)
    if data.ndim == 1:
        data = data.reshape(-1, 1)
    if edge_fade > 0.0 and not loop:
        data = fade_edges(data, edge_fade, sr)
    data = normalize(data, peak_db)
    pcm = np.clip(np.round(data * 32767.0), -32768.0, 32767.0).astype("<i2")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(data.shape[1])
        handle.setsampwidth(2)
        handle.setframerate(sr)
        handle.writeframes(pcm.tobytes())
    metrics = {
        "path": path,
        "duration": data.shape[0] / float(sr),
        "channels": int(data.shape[1]),
        "peak_db": peak_dbfs(data),
        "rms_db": rms_dbfs(data),
        "loop": bool(loop),
    }
    if loop:
        metrics.update(loop_metrics(data, sr))
    return metrics


def loop_metrics(data, sr=SR, window_seconds=1.0):
    """Стык петли: разница RMS первой и последней секунды (в дБ).

    t28 требует для дождя < 1 дБ; окно ровно 1 с, как в приёмке.
    """
    window = min(int(window_seconds * sr), data.shape[0] // 3)
    if window < 8:
        return {"seam_level_db": 0.0}
    head = data[:window]
    tail = data[-window:]
    head_rms = float(np.sqrt(np.mean(np.square(head))))
    tail_rms = float(np.sqrt(np.mean(np.square(tail))))
    ratio = 20.0 * math.log10(max(tail_rms, 1e-9) / max(head_rms, 1e-9))
    return {"seam_level_db": ratio}


# ---------------------------------------------------------------------------
# Шум и «воздух»
# ---------------------------------------------------------------------------


def white(n, rng):
    return rng.standard_normal(n)


def rain_drops(n, rng, count):
    left = np.zeros(n)
    right = np.zeros(n)
    length = int(0.02 * SR)
    window = np.exp(-np.arange(length) / (0.0035 * SR))
    for _ in range(count):
        start = int(rng.integers(0, max(1, n - length)))
        drop = rng.standard_normal(length) * window * rng.uniform(0.0008, 0.0045)
        pan = float(rng.uniform(-1.0, 1.0))
        left[start:start + length] += drop * (1.0 - max(0.0, pan))
        right[start:start + length] += drop * (1.0 + min(0.0, pan))
    return left, right


def crackle(n, rng, rate):
    out = np.zeros(n)
    length = int(0.012 * SR)
    window = np.exp(-np.arange(length) / (0.0022 * SR))
    count = max(1, int(n / SR * rate))
    for _ in range(count):
        start = int(rng.integers(0, max(1, n - length)))
        out[start:start + length] += (
            rng.standard_normal(length) * window * rng.uniform(0.04, 0.16)
        )
    return out


# ---------------------------------------------------------------------------
# Окружение
# ---------------------------------------------------------------------------


# --- Мягкий дождь (t28) ------------------------------------------------------
#
# Пользователь: «дождь слишком громкий и раздражающий, сделай мягким». Поэтому
# у дождя свой рецепт, отличный от прочих петель:
#   * шум только 200-2500 Гц, выше 2 кГц спад -6 дБ/октаву (одно-полюсный срез),
#     никакого «шелеста» 5-15 кГц;
#   * низкочастотный гул города 40-120 Гц, очень тихий;
#   * вместо капель-«тиканий» — редкие мягкие «плюхи» (синус 65-140 Гц) с атакой
#     30 мс и затуханием 120-200 мс, не чаще ~2/с и не громче 13% от шума;
#   * пик петель -6 dBFS (дождь — фон, он не должен перекрывать шаги и голос);
#   * пара rain_light/rain_heavy выравнивается по RMS (±1 дБ), разница — в
#     плотности и спектре, а не в громкости;
#   * кроссфейд хвоста в начало 0.5 с, уровень первой и последней секунды
#     выравнивается (стык < 1 дБ).

RAIN_PEAK_DBFS = -6.0
RAIN_CROSSFADE = 0.5
RAIN_LIGHT_SECONDS = 24.0
RAIN_HEAVY_SECONDS = 28.0
RAIN_MAX_PLOPS_PER_SECOND = 4.0
RAIN_PLOP_RELATIVE = 0.13  # доля от пика шума; задание допускает до 0.15

_RAIN_CACHE = {}
_RAIN_META = {}


def rain_texture(n, rng, low_cut, high_corner):
    """Шум дождя: срез снизу + спад -6 дБ/окт выше high_corner."""
    def gain(freqs):
        shape = band_gain(freqs, low_cut, 0.0, 3.0)
        shape = shape / np.sqrt(1.0 + (freqs / high_corner) ** 2.0)
        return shape

    return fft_filter(rng.standard_normal(n), gain)


def rain_ground_hum(n, rng, level):
    """Тихий низкочастотный гул города 40-120 Гц (RMS = level)."""
    t = time_axis(n)
    hum = np.zeros(n)
    for freq in (42.0, 58.0, 76.0, 96.0, 112.0):
        lfo = 0.8 + 0.2 * np.sin(
            2.0 * np.pi * rng.uniform(0.02, 0.06) * t + rng.uniform(0.0, 6.28)
        )
        hum += np.sin(2.0 * np.pi * freq * t + rng.uniform(0.0, 6.28)) * lfo / math.sqrt(freq / 60.0)
    hum = hum / max(rms_linear(hum), 1e-9)
    return hum * level


def rain_soft_plops(n, rng, count, amplitude):
    """Мягкие «плюхи»: длинное затухание, без резких атак и без щелчков."""
    out = np.zeros(n)
    for _ in range(count):
        length = int(round(rng.uniform(0.28, 0.46) * SR))
        start = int(rng.integers(0, max(1, n - length)))
        t = time_axis(length)
        freq = float(rng.uniform(65.0, 140.0))
        attack = np.minimum(1.0, t / 0.03)
        env = attack * np.exp(-t / float(rng.uniform(0.12, 0.20)))
        tone = np.sin(2.0 * np.pi * freq * t) + 0.25 * np.sin(
            2.0 * np.pi * freq * 2.03 * t + 0.7
        )
        out[start:start + length] += tone * env * amplitude
    return out


def synth_rain(duration, seed, variant):
    """Одна петля дождя (mono, уже с кроссфейдом). Возвращает (data, meta)."""
    rng = np.random.default_rng(seed)
    n = int(round((duration + RAIN_CROSSFADE) * SR))
    if variant == "light":
        low_cut, high_corner = 215.0, 2500.0
        bed = rain_texture(n, rng, low_cut, high_corner)
        hum_level = 0.06
        plop_rate = 0.55
    else:
        low_cut, high_corner = 165.0, 1800.0
        # Плотнее и ниже: два слоя шума, больше низкого гула, чаще «плюхи».
        bed = 0.80 * rain_texture(n, rng, low_cut, high_corner)
        bed += 0.55 * rain_texture(n, rng, 140.0, 1150.0)
        hum_level = 0.13
        plop_rate = 1.7
    bed = bed / max(rms_linear(bed), 1e-9)
    hum = rain_ground_hum(n, rng, hum_level)
    plop_count = int(round(duration * min(plop_rate, RAIN_MAX_PLOPS_PER_SECOND)))
    plop_amplitude = RAIN_PLOP_RELATIVE * float(np.max(np.abs(bed)))
    plops = rain_soft_plops(n, rng, plop_count, plop_amplitude)
    signal = bed + hum + plops
    # Очень медленное «дыхание» ливня (+-0.17 дБ): незаметно на слух, но не
    # разъезжается с уровнем первой/последней секунды на стыке петли.
    t = time_axis(n)
    signal *= 1.0 + 0.02 * np.sin(2.0 * np.pi * 0.035 * t + rng.uniform(0.0, 6.28))
    looped = crossfade_loop(signal, RAIN_CROSSFADE)
    meta = {
        "variant": variant,
        "seconds": duration,
        "band_hz": (low_cut, high_corner),
        "hum_rms": hum_level,
        "plop_rate": plop_count / duration,
        "plops": plop_count,
    }
    return looped, meta


def balance_rain_pair(light, heavy, peak_db=RAIN_PEAK_DBFS):
    """Обе петли ставим в один потолок пика (peak_db).

    Громкость выравнивается не срезом пика, а составом: у light и heavy разные
    полосы, плотность и доля «плюх», поэтому при одном пике их RMS должны сойтись
    в пределах ±1 дБ (это проверяет build_assets и печатает в лог).
    """
    return normalize(light, peak_db), normalize(heavy, peak_db)


def rain_loop(variant):
    """Пара дождя считается один раз: обе петли выравниваются друг по другу."""
    if not _RAIN_CACHE:
        light, light_meta = synth_rain(RAIN_LIGHT_SECONDS, 4101, "light")
        heavy, heavy_meta = synth_rain(RAIN_HEAVY_SECONDS, 4102, "heavy")
        light, heavy = balance_rain_pair(light, heavy, RAIN_PEAK_DBFS)
        _RAIN_CACHE["light"] = light
        _RAIN_CACHE["heavy"] = heavy
        _RAIN_META["light"] = light_meta
        _RAIN_META["heavy"] = heavy_meta
        _RAIN_META["rms_diff_db"] = rms_dbfs(light) - rms_dbfs(heavy)
    return _RAIN_CACHE[variant].copy()


def make_city_hum(duration, seed, fade):
    rng = np.random.default_rng(seed)
    n = int(round((duration + fade) * SR))
    t = time_axis(n)
    hum = (
        0.50 * np.sin(2.0 * np.pi * 48.0 * t)
        + 0.22 * np.sin(2.0 * np.pi * 96.0 * t + 0.7)
        + 0.11 * np.sin(2.0 * np.pi * 143.0 * t + 2.1)
        + 0.05 * np.sin(2.0 * np.pi * 191.0 * t + 0.3)
    )
    hum *= 0.85 + 0.15 * np.sin(2.0 * np.pi * 0.03 * t + 1.0)
    left = hum * 0.55
    right = hum * 0.55
    for index in range(2):
        traffic = fft_filter(white(n, rng), lambda f: band_gain(f, 70.0, 1500.0, 1.0))
        air = fft_filter(white(n, rng), lambda f: band_gain(f, 1500.0, 9000.0, 1.0))
        if index == 0:
            left = left + 0.55 * traffic + 0.10 * air
        else:
            right = right + 0.55 * traffic + 0.10 * air
    data = np.stack([left, right], axis=1)
    return crossfade_loop(data, fade), fade


def make_neon_hum(duration, seed, fade):
    rng = np.random.default_rng(seed)
    n = int(round((duration + fade) * SR))
    t = time_axis(n)
    buzz = np.zeros(n)
    for harmonic in range(1, 9):
        buzz += (0.32 / harmonic) * np.sin(
            2.0 * np.pi * 100.0 * harmonic * t + rng.uniform(0.0, 6.28)
        )
    am = 0.78 + 0.22 * np.sin(2.0 * np.pi * 7.3 * t)
    hum = 0.16 * np.sin(2.0 * np.pi * 50.0 * t + 0.4)
    left = (buzz + hum) * am * 0.55 + 0.35 * crackle(n, rng, 3.0)
    right = (buzz + hum) * am * 0.55 + 0.35 * crackle(n, rng, 3.0)
    data = np.stack([left, right], axis=1)
    return crossfade_loop(data, fade), fade


def make_water_wind(duration, seed, fade):
    rng = np.random.default_rng(seed)
    n = int(round((duration + fade) * SR))
    t = time_axis(n)
    wind_env = 0.55 + 0.45 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 0.055 * t + 0.4))
    swell = np.maximum(0.0, np.sin(2.0 * np.pi * 0.17 * t)) ** 2
    left = np.zeros(n)
    right = np.zeros(n)
    for channel in range(2):
        wind = fft_filter(white(n, rng), lambda f: band_gain(f, 90.0, 2600.0, 1.0))
        water = fft_filter(white(n, rng), lambda f: band_gain(f, 300.0, 5000.0, 1.0))
        wind = wind * wind_env * 0.45
        water = water * swell * 0.35
        if channel == 0:
            left = wind + water
        else:
            right = wind + water
    bubbles_l, bubbles_r = rain_drops(n, rng, int(duration * 1.2))
    data = np.stack([left + 1.6 * bubbles_l, right + 1.6 * bubbles_r], axis=1)
    return crossfade_loop(data, fade), fade


# ---------------------------------------------------------------------------
# Короткие эффекты
# ---------------------------------------------------------------------------


def make_step_asphalt(seed, variant):
    rng = np.random.default_rng(seed)
    n = int(0.24 * SR)
    t = time_axis(n)
    thump = np.sin(2.0 * np.pi * (60.0 + 4.0 * variant) * t)
    thump *= np.exp(-t / 0.05) * np.minimum(1.0, t / 0.004)
    crunch = fft_filter(white(n, rng), lambda f: band_gain(f, 900.0, 9000.0, 1.0))
    crunch *= np.exp(-t / 0.032) * (0.8 + 0.2 * np.sin(2.0 * np.pi * 37.0 * t))
    grit = fft_filter(white(n, rng), lambda f: band_gain(f, 2600.0, 13000.0, 1.0))
    grit *= np.exp(-t / 0.018) * 0.45
    return 0.75 * thump + 0.55 * crunch + grit


def make_step_wood(seed, variant):
    rng = np.random.default_rng(seed)
    n = int(0.3 * SR)
    t = time_axis(n)
    body = (
        0.55 * np.sin(2.0 * np.pi * (170.0 + 26.0 * variant) * t)
        + 0.35 * np.sin(2.0 * np.pi * (430.0 + 60.0 * variant) * t + 0.5)
        + 0.18 * np.sin(2.0 * np.pi * 1180.0 * t + 1.2)
    )
    body *= np.exp(-t / 0.062) * np.minimum(1.0, t / 0.002)
    click = fft_filter(white(n, rng), lambda f: band_gain(f, 1500.0, 8000.0, 1.0))
    click *= np.exp(-t / 0.012) * 0.5
    creak = np.sin(2.0 * np.pi * (620.0 + 90.0 * variant) * t) * np.exp(-t / 0.09) * 0.08
    return body + click + creak


def make_horn(seed):
    n = int(3.2 * SR)
    t = time_axis(n)
    signal = np.zeros(n)
    for freq in (196.0, 246.94):
        vibrato = 0.35 * np.sin(2.0 * np.pi * 5.1 * t)
        signal += np.sin(2.0 * np.pi * freq * t + vibrato)
        signal += 0.3 * np.sin(2.0 * np.pi * freq * 2.0 * t + 0.4)
    envelope = np.minimum(1.0, t / 0.06) * np.exp(-np.maximum(t - 0.35, 0.0) / 0.55)
    signal *= envelope * 0.5
    signal = fft_filter(signal, lambda f: band_gain(f, 110.0, 1700.0, 1.0))
    echoes = np.zeros(n)
    for delay, gain in ((0.28, 0.34), (0.56, 0.2), (0.95, 0.11)):
        shift = int(delay * SR)
        echoes[shift:] += signal[:-shift] * gain
    return signal * 0.7 + fft_filter(echoes, lambda f: band_gain(f, 90.0, 1200.0, 1.0))


def make_door_creak(seed):
    rng = np.random.default_rng(seed)
    n = int(1.7 * SR)
    t = time_axis(n)
    freq = 880.0 + 240.0 * np.sin(2.0 * np.pi * 0.7 * t) + 110.0 * np.sin(2.0 * np.pi * 3.1 * t)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    squeak = np.sin(phase) * (0.55 + 0.45 * np.sin(2.0 * np.pi * 2.3 * t + 1.1))
    envelope = np.minimum(1.0, t / 0.22) * np.exp(-np.maximum(t - 0.62, 0.0) / 0.32)
    squeak *= envelope * 0.55
    rumble = fft_filter(white(n, rng), lambda f: band_gain(f, 70.0, 380.0, 1.0))
    rumble *= np.exp(-t / 0.55) * 0.35
    return squeak + rumble


def make_click(seed):
    rng = np.random.default_rng(seed)
    n = int(0.09 * SR)
    t = time_axis(n)
    body = np.sin(2.0 * np.pi * 2100.0 * t) * np.exp(-t / 0.012)
    body += 0.4 * np.sin(2.0 * np.pi * 3300.0 * t) * np.exp(-t / 0.006)
    tick = white(n, rng) * np.exp(-t / 0.003) * 0.25
    return 0.6 * body + tick


def make_pickup(seed):
    n = int(0.62 * SR)
    out = np.zeros(n)
    notes = ((880.0, 0.0, 0.5), (1174.66, 0.09, 0.4), (1760.0, 0.18, 0.3))
    for freq, start, amplitude in notes:
        offset = int(start * SR)
        local = time_axis(n - offset)
        bell = (
            np.sin(2.0 * np.pi * freq * local)
            + 0.45 * np.sin(2.0 * np.pi * freq * 2.01 * local + 0.3)
            + 0.18 * np.sin(2.0 * np.pi * freq * 3.02 * local + 0.9)
        )
        bell *= np.exp(-local / 0.17) * np.minimum(1.0, local / 0.004)
        out[offset:] += bell * amplitude
    return out


# --- Пистолет (t30; ассеты — t43) -------------------------------------------
#
# Три сухих one-shot под WeaponController: выстрел, перезарядка, пустой магазин.
# Все короткие, mono 44.1 кГц, пик -1 dBFS (нормализует write_wav), без хвостов
# кроме явно заданного реверба у выстрела.


def _metal_tick(rng, length, low, high, decay, attack=0.0004):
    """Короткий металлический щелчок: шум в полосе low-high с быстрым спадом."""
    t = time_axis(length)
    tick = fft_filter(white(length, rng), lambda f: band_gain(f, low, high, 2.0))
    tick *= np.minimum(1.0, t / attack) * np.exp(-t / decay)
    return tick / max(float(np.max(np.abs(tick))), 1e-9)


def make_pistol_fire(seed):
    """Сухой выстрел ~0.45 с: боёк, шумовой выхлоп, низкий бум, короткий реверб."""
    rng = np.random.default_rng(seed)
    n = int(0.45 * SR)
    out = np.zeros(n)

    # 1) Щелчок бойка: 5 мс, 1-3 кГц.
    add_at(out, 0.0, _metal_tick(rng, int(0.006 * SR), 1000.0, 3000.0, 0.0012, 0.0003), 0.55)

    # 2) Шумовой выхлоп: 150-900 Гц, атака 3 мс, спад 80 мс.
    blast_n = int(0.30 * SR)
    tb = time_axis(blast_n)
    blast = fft_filter(white(blast_n, rng), lambda f: band_gain(f, 150.0, 900.0, 2.0))
    blast *= np.minimum(1.0, tb / 0.003) * np.exp(-tb / 0.08)
    blast /= max(float(np.max(np.abs(blast))), 1e-9)
    add_at(out, 0.002, blast, 1.0)

    # 3) Низкий бум: 80 -> 58 Гц, 180 мс.
    boom_n = int(0.18 * SR)
    tbo = time_axis(boom_n)
    freq = 58.0 + 22.0 * np.exp(-tbo / 0.03)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    boom = np.sin(phase) + 0.30 * np.sin(2.0 * phase + 0.4)
    boom *= np.minimum(1.0, tbo / 0.004) * np.exp(-tbo / 0.06)
    boom /= max(float(np.max(np.abs(boom))), 1e-9)
    add_at(out, 0.001, boom, 0.9)

    # 4) Хвост-реверб 400 мс на -24 dBFS от пика.
    tail_n = int(0.40 * SR)
    tt = time_axis(tail_n)
    tail = fft_filter(white(tail_n, rng), lambda f: band_gain(f, 250.0, 4000.0, 1.0))
    tail *= np.minimum(1.0, tt / 0.04) * np.exp(-tt / 0.17)
    tail /= max(float(np.max(np.abs(tail))), 1e-9)
    add_at(out, 0.06, tail, 0.07)
    return out


def make_pistol_reload(seed):
    """Перезарядка ~0.75 с: клац магазина, вставка, затвор; паузы 180/220 мс."""
    rng = np.random.default_rng(seed)
    n = int(0.75 * SR)
    out = np.zeros(n)

    # 1) Магазин: клац 2-4 кГц, 60 мс.
    add_at(out, 0.0, _metal_tick(rng, int(0.06 * SR), 2000.0, 4000.0, 0.012), 0.9)

    # 2) Вставка: низкий стук 180-260 Гц (пауза 180 мс).
    knock_n = int(0.10 * SR)
    tk = time_axis(knock_n)
    knock = (
        np.sin(2.0 * np.pi * 205.0 * tk)
        + 0.45 * np.sin(2.0 * np.pi * 310.0 * tk + 0.6)
        + 0.20 * np.sin(2.0 * np.pi * 520.0 * tk + 1.2)
    )
    knock *= np.minimum(1.0, tk / 0.003) * np.exp(-tk / 0.035)
    knock /= max(float(np.max(np.abs(knock))), 1e-9)
    add_at(out, 0.18, knock, 0.8)

    # 3) Затвор: 1.5-3 кГц, 30 мс (пауза 220 мс).
    add_at(out, 0.40, _metal_tick(rng, int(0.03 * SR), 1500.0, 3000.0, 0.008, 0.0003), 0.75)
    return out


def make_pistol_empty(seed):
    """Пустой магазин: один сухой щелчок 1.8-3.5 кГц, 0.15 с, без хвоста."""
    rng = np.random.default_rng(seed)
    n = int(0.15 * SR)
    t = time_axis(n)
    click = fft_filter(white(n, rng), lambda f: band_gain(f, 1800.0, 3500.0, 2.0))
    click *= np.minimum(1.0, t / 0.0004) * np.exp(-t / 0.02)
    return click


# --- Машина (t53; скрипт — scripts/vehicles/car.gd) --------------------------
#
# car.gd на входе и выходе просит AudioManager.play_sfx("car_door"), файла не
# было — в живом логе 12 WARNING «play_sfx: файл не найден — car_door».
# Дверца: короткая металлическая защёлка 0.22 с. Петля холостого хода — бонус
# (2.2 с, стык <= 1 дБ, пик -6 dBFS): AudioManager пока умеет только play_sfx,
# запускать её отдельным AudioStreamPlayer'ом (рецепт — docs/audio/README.md).

CAR_ENGINE_PEAK_DBFS = -6.0


def make_car_door(seed):
    """Дверца машины: защёлка 180-900 Гц (атака 3 мс, спад 100 мс) + низкий стук."""
    rng = np.random.default_rng(seed)
    n = int(0.22 * SR)
    out = np.zeros(n)

    # 1) Металлическая защёлка: шум 180-900 Гц с быстрой атакой.
    latch_n = int(0.16 * SR)
    tl = time_axis(latch_n)
    latch = fft_filter(white(latch_n, rng), lambda f: band_gain(f, 180.0, 900.0, 2.0))
    latch *= np.minimum(1.0, tl / 0.003) * np.exp(-tl / 0.10)
    latch /= max(float(np.max(np.abs(latch))), 1e-9)
    add_at(out, 0.0, latch, 0.85)

    # 2) Короткий металлический призвук поверх защёлки.
    add_at(out, 0.0, _metal_tick(rng, int(0.035 * SR), 1200.0, 2600.0, 0.007, 0.0005), 0.30)

    # 3) Низкий стук 70-90 Гц в конце.
    knock_n = int(0.10 * SR)
    tk = time_axis(knock_n)
    knock = (
        np.sin(2.0 * np.pi * 78.0 * tk)
        + 0.30 * np.sin(2.0 * np.pi * 156.0 * tk + 0.5)
    )
    knock *= np.minimum(1.0, tk / 0.004) * np.exp(-tk / 0.045)
    knock /= max(float(np.max(np.abs(knock))), 1e-9)
    add_at(out, 0.10, knock, 0.55)
    return out


def make_car_engine_loop(duration=2.2, seed=2901, fade=0.35):
    """Петля холостого хода: гул 55-140 Гц + шум, стык ровный (кроссфейд)."""
    rng = np.random.default_rng(seed)
    n = int(round((duration + fade) * SR))
    t = time_axis(n)

    hum = np.zeros(n)
    for harmonic, amplitude in ((1, 0.55), (2, 0.30), (3, 0.16), (4, 0.09)):
        hum += amplitude * np.sin(2.0 * np.pi * 62.0 * harmonic * t + rng.uniform(0.0, 6.28))
    # Дрожание частоты (не уровня): добавляет «живости», стык не портит.
    hum *= 1.0 + 0.004 * np.sin(2.0 * np.pi * 3.1 * t + 0.7)
    hum = fft_filter(hum, lambda f: band_gain(f, 55.0, 140.0, 2.0))
    hum /= max(float(np.max(np.abs(hum))), 1e-9)

    rumble = fft_filter(white(n, rng), lambda f: band_gain(f, 55.0, 140.0, 2.0))
    rumble /= max(float(np.max(np.abs(rumble))), 1e-9)

    air = fft_filter(white(n, rng), lambda f: band_gain(f, 300.0, 1200.0, 1.0))
    air /= max(float(np.max(np.abs(air))), 1e-9)

    signal = 0.78 * hum + 0.30 * rumble + 0.05 * air
    return crossfade_loop(signal, fade)


# ---------------------------------------------------------------------------
# Музыка
# ---------------------------------------------------------------------------

BPM = 90.0
BEAT = 60.0 / BPM
BAR = 4.0 * BEAT
BAR_COUNT = 16
## Сколько тактов аранжировки дорисовать ПОСЛЕ точки петли.
## Хвост нужен кроссфейду: раньше за 16-м тактом шла тишина, и первая секунда
## петли оказывалась на 7 дБ тише последней. 2 такта = 5.33 с > любого fade.
MUSIC_TAIL_BARS = 2

# A minor: i - VI - III - VII. (имя, бас, аккордовые тоны)
CHORDS = (
    ("Am", 55.00, (110.00, 130.81, 164.81, 220.00)),
    ("F", 43.65, (87.31, 130.81, 174.61, 261.63)),
    ("C", 65.41, (130.81, 164.81, 196.00, 261.63)),
    ("G", 49.00, (98.00, 146.83, 196.00, 246.94)),
)


def pad_note(freq, n, rng):
    t = time_axis(n)
    signal = (
        0.50 * np.sin(2.0 * np.pi * freq * t)
        + 0.25 * np.sin(2.0 * np.pi * freq * 2.0 * t + 0.3)
        + 0.12 * np.sin(2.0 * np.pi * freq * 3.0 * t + 1.1)
        + 0.07 * np.sin(2.0 * np.pi * freq * 4.03 * t + 2.0)
    )
    attack = min(n, int(0.32 * SR))
    envelope = np.ones(n)
    if attack > 1:
        envelope[:attack] = np.linspace(0.0, 1.0, attack) ** 1.3
    release = min(n, int(0.5 * SR))
    if release > 1:
        envelope[-release:] *= np.linspace(1.0, 0.0, release)
    vibrato = 1.0 + 0.006 * np.sin(2.0 * np.pi * 0.23 * t + rng.uniform(0.0, 6.28))
    return signal * envelope * vibrato * 0.3


def bass_note(freq, n):
    t = time_axis(n)
    signal = np.sin(2.0 * np.pi * freq * t) + 0.35 * np.sin(2.0 * np.pi * freq * 2.0 * t)
    envelope = np.exp(-t / 0.38) * np.minimum(1.0, t / 0.01)
    return signal * envelope * 0.5


def pluck_note(freq, n, rng):
    t = time_axis(n)
    signal = (
        np.sin(2.0 * np.pi * freq * t)
        + 0.35 * np.sin(2.0 * np.pi * freq * 2.0 * t + rng.uniform(0.0, 0.5))
        + 0.12 * np.sin(2.0 * np.pi * freq * 3.0 * t + 1.4)
    )
    envelope = np.exp(-t / 0.22) * np.minimum(1.0, t / 0.004)
    return signal * envelope * 0.25


def hat_noise(n, rng):
    noise = rng.standard_normal(n)
    bright = np.diff(np.concatenate(([0.0], noise)))
    t = time_axis(n)
    return bright * np.exp(-t / 0.028) * 0.09


def kick_drum(n):
    t = time_axis(n)
    freq = 52.0 + 72.0 * np.exp(-t / 0.028)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase) * np.exp(-t / 0.13) * 0.55


def make_music(seed=7, fade=3.0):
    rng = np.random.default_rng(seed)
    total_seconds = BAR_COUNT * BAR
    n = int(round((total_seconds + fade) * SR))
    arrange_bars = BAR_COUNT + MUSIC_TAIL_BARS
    left = np.zeros(n)
    right = np.zeros(n)

    # 1. Пады по такту (стерео-расстройка).
    for bar in range(arrange_bars):
        name, bass_freq, tones = CHORDS[bar % len(CHORDS)]
        start = bar * BAR
        length = int(round(BAR * 1.06 * SR))
        for tone in tones:
            add_at(left, start, pad_note(tone, length, rng), 0.30)
            add_at(right, start, pad_note(tone * 1.0025, length, rng), 0.30)

    # 2. Бас: каждый бит, октава на слабых долях.
    for beat in range(arrange_bars * 4):
        name, bass_freq, tones = CHORDS[(beat // 4) % len(CHORDS)]
        freq = bass_freq * (2.0 if beat % 2 == 1 else 1.0)
        length = int(round(BEAT * 0.88 * SR))
        tone = bass_note(freq, length)
        add_at(left, beat * BEAT, tone, 0.55)
        add_at(right, beat * BEAT, tone, 0.55)

    # 3. Арпеджио восьмыми.
    for step in range(arrange_bars * 8):
        name, bass_freq, tones = CHORDS[(step // 8) % len(CHORDS)]
        freq = tones[(step * 2) % len(tones)] * 2.0
        length = int(round(BEAT * 0.55 * SR))
        note = pluck_note(freq, length, rng)
        pan = 0.35 if step % 2 == 0 else -0.35
        add_at(left, step * BEAT * 0.5, note, 1.0 - max(0.0, pan))
        add_at(right, step * BEAT * 0.5, note, 1.0 + min(0.0, pan))

    # 4. Хэты и мягкий бочка-пульс.
    for step in range(arrange_bars * 8):
        length = int(0.09 * SR)
        hat = hat_noise(length, rng)
        add_at(left, step * BEAT * 0.5, hat, 0.9)
        add_at(right, step * BEAT * 0.5, hat, 0.8)
    for bar in range(arrange_bars):
        for beat_index in (0, 2):
            length = int(0.25 * SR)
            kick = kick_drum(length)
            add_at(left, bar * BAR + beat_index * BEAT, kick, 0.5)
            add_at(right, bar * BAR + beat_index * BEAT, kick, 0.5)

    data = np.stack([left, right], axis=1)
    # Небольшая «компрессия» мягким tanh, чтобы пики были музыкальными.
    data = np.tanh(data * 1.1) * 0.92
    # Музыка периодична (16 тактов = 4 полных цикла аккордов), поэтому хвост и
    # начало — один и тот же материал: линейное окно держит уровень ровным.
    return crossfade_loop(data, fade, equal_power=False), fade


# ---------------------------------------------------------------------------
# Реестр ассетов
# ---------------------------------------------------------------------------

ASSETS = (
    # Окружение (петли). У дождя пик -6 dBFS: он фон и не должен перекрывать
    # шаги и голос; стык петель дождя должен быть ровным в пределах 1 дБ.
    {
        "path": "ambience/rain_light_loop.wav",
        "loop": True,
        "peak_db": RAIN_PEAK_DBFS,
        "seam_limit_db": 1.0,
        "factory": lambda: rain_loop("light"),
    },
    {
        "path": "ambience/rain_heavy_loop.wav",
        "loop": True,
        "peak_db": RAIN_PEAK_DBFS,
        "seam_limit_db": 1.0,
        "factory": lambda: rain_loop("heavy"),
    },
    {
        "path": "ambience/city_hum_loop.wav",
        "loop": True,
        "peak_db": PEAK_LIMIT_DBFS,
        "seam_limit_db": 6.0,
        "factory": lambda: make_city_hum(30.0, 1201, 2.0)[0],
    },
    {
        "path": "ambience/neon_hum_loop.wav",
        "loop": True,
        "peak_db": PEAK_LIMIT_DBFS,
        "seam_limit_db": 6.0,
        "factory": lambda: make_neon_hum(22.0, 1301, 1.5)[0],
    },
    {
        "path": "ambience/water_wind_loop.wav",
        "loop": True,
        "peak_db": PEAK_LIMIT_DBFS,
        "seam_limit_db": 6.0,
        "factory": lambda: make_water_wind(26.0, 1401, 2.5)[0],
    },
    # Шаги (короткие, mono).
    {"path": "sfx/step_asphalt_01.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_asphalt(2101, 0)},
    {"path": "sfx/step_asphalt_02.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_asphalt(2102, 1)},
    {"path": "sfx/step_asphalt_03.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_asphalt(2103, 2)},
    {"path": "sfx/step_asphalt_04.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_asphalt(2104, 3)},
    {"path": "sfx/step_wood_01.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_wood(2201, 0)},
    {"path": "sfx/step_wood_02.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_step_wood(2202, 1)},
    # Атмосферные акценты и UI.
    {"path": "sfx/horn_distant.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_horn(2301)},
    {"path": "sfx/door_creak.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_door_creak(2401)},
    {"path": "sfx/ui_click.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_click(2501)},
    {"path": "sfx/pickup.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "seam_limit_db": 0.0, "factory": lambda: make_pickup(2601)},
    # Пистолет (t30, ассеты t43): выстрел, перезарядка, пустой магазин.
    # Фейд 0.2 мс: у выстрела и щелчка атака 0.3-0.4 мс, стандартные 3 мс
    # срезали бы сам транзиент.
    {"path": "sfx/pistol_fire.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "edge_fade": 0.0002, "seam_limit_db": 0.0, "factory": lambda: make_pistol_fire(2701)},
    {"path": "sfx/pistol_reload.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "edge_fade": 0.0002, "seam_limit_db": 0.0, "factory": lambda: make_pistol_reload(2702)},
    {"path": "sfx/pistol_empty.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "edge_fade": 0.0002, "seam_limit_db": 0.0, "factory": lambda: make_pistol_empty(2703)},
    # Машина (t53): дверца (car.gd зовёт play_sfx("car_door")) и петля холостого
    # хода. Петля лежит в sfx/, но помечена loop: пик -6 dBFS и стык <= 1 дБ.
    {"path": "sfx/car_door.wav", "loop": False, "peak_db": PEAK_LIMIT_DBFS,
     "edge_fade": 0.0005, "seam_limit_db": 0.0, "factory": lambda: make_car_door(2801)},
    {"path": "sfx/car_engine_loop.wav", "loop": True, "peak_db": CAR_ENGINE_PEAK_DBFS,
     "seam_limit_db": 1.0, "factory": lambda: make_car_engine_loop(2.2, 2802, 0.35)},
    # Музыка. Кроссфейд 3 с линейным окном (аранжировка периодична), хвост —
    # 2 дорисованных такта, поэтому стык первой/последней секунды ровный (≤2 дБ).
    {
        "path": "music/mus_night_shift_loop.wav",
        "loop": True,
        "peak_db": PEAK_LIMIT_DBFS,
        "seam_limit_db": 2.0,
        "factory": lambda: make_music(3001, 3.0)[0],
    },
)


# ---------------------------------------------------------------------------
# Проверка и отчёт
# ---------------------------------------------------------------------------


def read_wav_info(path):
    with wave.open(path, "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        frames = handle.getnframes()
        raw = handle.readframes(frames)
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels)
    info = {
        "channels": channels,
        "width": width,
        "rate": rate,
        "duration": frames / float(rate) if rate else 0.0,
        "peak_db": peak_dbfs(samples),
        "rms_db": rms_dbfs(samples),
        "dc": float(np.mean(samples)),
        "size": os.path.getsize(path),
    }
    return info


def collect_wavs(root=AUDIO_ROOT, include_voice=False):
    """WAV-файлы проекта. По умолчанию без assets/audio/voice: озвучку рендерит
    отдельный пайплайн (t13) со своими допусками (22050 Гц, mono)."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, AUDIO_ROOT).replace("\\", "/")
        if not include_voice and "voice" in rel_dir.split("/"):
            continue
        for filename in sorted(filenames):
            if filename.lower().endswith(".wav"):
                found.append(os.path.join(dirpath, filename))
    return sorted(found)


def collect_voice_wavs():
    """Только озвучка (assets/audio/voice/**)."""
    voice_marker = os.sep + "voice" + os.sep
    return [path for path in collect_wavs(include_voice=True) if voice_marker in path]


def load_wav_samples(path):
    with wave.open(path, "rb") as handle:
        channels = handle.getnchannels()
        frames = handle.getnframes()
        raw = handle.readframes(frames)
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels)
    return samples


def verify_assets(verbose=True):
    """Проверяет сгенерированные файлы. Возвращает (ok, проблемы, строки отчёта)."""
    issues = []
    rows = []
    files = collect_wavs()
    if len(files) < MIN_FILES:
        issues.append("файлов %d < %d" % (len(files), MIN_FILES))
    for path in files:
        rel = os.path.relpath(path, PROJECT_ROOT).replace("\\", "/")
        info = read_wav_info(path)
        if info["rate"] != SR:
            issues.append("%s: sample rate %d != %d" % (rel, info["rate"], SR))
        if info["width"] != 2:
            issues.append("%s: не 16 бит (width=%d)" % (rel, info["width"]))
        if info["peak_db"] > PEAK_LIMIT_DBFS + 0.1:
            issues.append("%s: пик %.2f dBFS выше -1 dBFS" % (rel, info["peak_db"]))
        if info["duration"] < 0.05:
            issues.append("%s: слишком короткий (%.3f с)" % (rel, info["duration"]))
        if abs(info["dc"]) > 0.02:
            issues.append("%s: DC-смещение %.4f" % (rel, info["dc"]))
        # Петля — не только ambience/music: car_engine_loop лежит в sfx/.
        is_loop = "/ambience/" in rel or "/music/" in rel or rel.endswith("_loop.wav")
        rows.append(
            "%-38s %7.2f s  %dch  peak %6.2f dBFS  rms %6.2f dBFS  %s"
            % (
                rel,
                info["duration"],
                info["channels"],
                info["peak_db"],
                info["rms_db"],
                "loop" if is_loop else "sfx ",
            )
        )
        if verbose:

            print(rows[-1])
    # Озвучку (assets/audio/voice) рендерит отдельный пайплайн t13: там допустимы
    # 22050 Гц и другой уровень. Здесь проверяем только читаемость и длительность.
    voice_files = collect_voice_wavs()
    for path in voice_files:
        rel = os.path.relpath(path, PROJECT_ROOT).replace("\\", "/")
        try:
            info = read_wav_info(path)
        except Exception as error:  # noqa: BLE001 - отчёт не должен падать на битом файле
            issues.append("%s: не читается (%s)" % (rel, error))
            continue
        if info["duration"] < 0.05:
            issues.append("%s: слишком короткий (%.3f с)" % (rel, info["duration"]))
    if voice_files and verbose:
        print("Озвучка: %d файлов в assets/audio/voice (вне таблицы, проверены на читаемость)"
              % len(voice_files))
    return (not issues), issues, rows


def write_report(metrics_list, issues):
    lines = []
    lines.append("T12 AUDIO REPORT — синтезированные ассеты «Ночной смены» (дождь — t28)")
    lines.append(
        "Формат: WAV PCM 16 бит, 44.1 кГц. Пик: дождь %.1f dBFS (моно, "
        "кроссфейд 0.5 с), остальные файлы %.1f dBFS." % (
            RAIN_PEAK_DBFS, PEAK_LIMIT_DBFS
        )
    )
    lines.append("")
    lines.append("%-38s %9s  %s  %-11s %-11s %-10s %s" % (
        "файл", "длит., с", "ch", "пик, dBFS", "rms, dBFS", "тип", "стык петли, dB"
    ))
    for item in metrics_list:
        seam = item.get("seam_level_db")
        seam_text = ("%+.2f" % seam) if isinstance(seam, float) else "—"
        lines.append("%-38s %9.2f  %d  %11.2f  %11.2f  %-10s %s" % (
            item["path"].replace("\\", "/"),
            item["duration"],
            item["channels"],
            item["peak_db"],
            item["rms_db"],
            "loop" if item["loop"] else "sfx",
            seam_text,
        ))
    lines.append("")
    lines.append("Файлов: %d" % len(metrics_list))
    voice_count = len(collect_voice_wavs())
    if voice_count:
        lines.append(
            "Озвучка: %d файлов в assets/audio/voice — рендерит t13 (piper, 22050 Гц), "
            "в проверку пика/частоты не входит." % voice_count
        )
    if issues:
        lines.append("ПРОБЛЕМЫ (%d):" % len(issues))
        for issue in issues:
            lines.append("  - " + issue)
    else:
        lines.append("Проверка: ОК — нормализация, формат, длительность и стыки петель.")
    text = "\n".join(lines) + "\n"
    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    with open(REPORT_PATH, "w", encoding="utf-8") as handle:
        handle.write(text)
    return text


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def scan_metrics():
    """Метрики готовых файлов (без синтеза) — для пересборки отчёта."""
    metrics = []
    for path in collect_wavs():
        rel = os.path.relpath(path, PROJECT_ROOT)
        rel_posix = rel.replace("\\", "/")
        info = read_wav_info(path)
        is_loop = (
            "/ambience/" in rel_posix
            or "/music/" in rel_posix
            or rel_posix.endswith("_loop.wav")
        )
        item = {
            "path": rel,
            "duration": info["duration"],
            "channels": info["channels"],
            "peak_db": info["peak_db"],
            "rms_db": info["rms_db"],
            "loop": is_loop,
        }
        if is_loop:
            item.update(loop_metrics(load_wav_samples(path)))
        metrics.append(item)
    return metrics


def print_rain_summary(metrics_list):
    """Явная сводка по дождю: пик, RMS, стык, частота «плюх», полоса."""
    found = {}
    for item in metrics_list:
        rel = item["path"].replace("\\", "/")
        for variant in ("light", "heavy"):
            if "rain_%s_loop" % variant in rel:
                found[variant] = item
    for variant in ("light", "heavy"):
        item = found.get(variant)
        if item is None:
            continue
        meta = _RAIN_META.get(variant, {})
        band = meta.get("band_hz", (0.0, 0.0))
        seam = item.get("seam_level_db")
        print(
            "[rain] rain_%s: peak %.2f dBFS, RMS %.2f dBFS, стык %+.2f dB, "
            "плюхи %.2f/с, полоса %.0f-%.0f Гц"
            % (
                variant,
                item["peak_db"],
                item["rms_db"],
                seam if isinstance(seam, float) else 0.0,
                meta.get("plop_rate", 0.0),
                band[0],
                band[1],
            )
        )
    if "rms_diff_db" in _RAIN_META:
        print("[rain] RMS light/heavy: %+.2f dB (цель <= 1 dB)" % _RAIN_META["rms_diff_db"])


def build_assets():
    metrics_list = []
    issues = []
    for asset in ASSETS:
        relative_path = str(asset["path"])
        target = os.path.join(AUDIO_ROOT, *relative_path.split("/"))
        data = asset["factory"]()
        item = write_wav(
            target,
            data,
            peak_db=float(asset["peak_db"]),
            edge_fade=float(asset.get("edge_fade", 0.003)),
            loop=bool(asset["loop"]),
        )
        item["path"] = os.path.relpath(target, PROJECT_ROOT)
        metrics_list.append(item)
        seam = item.get("seam_level_db")
        seam_text = ("%+.2f" % seam) if isinstance(seam, float) else "  --  "
        print(
            "%-38s %7.2f s  %dch  peak %6.2f dBFS  rms %6.2f dBFS  стык %s dB  %s"
            % (
                item["path"].replace("\\", "/"),
                item["duration"],
                item["channels"],
                item["peak_db"],
                item["rms_db"],
                seam_text,
                "loop" if item["loop"] else "sfx",
            )
        )
        if item["peak_db"] > float(asset["peak_db"]) + 0.1:
            issues.append("%s: пик %.2f dBFS выше заданного %.1f dBFS" % (
                item["path"], item["peak_db"], float(asset["peak_db"])
            ))
        if item["duration"] < 0.05:
            issues.append("%s: слишком короткий" % item["path"])
        if relative_path.endswith("rain_light_loop.wav") and "rms_diff_db" in _RAIN_META:
            rms_gap = float(_RAIN_META["rms_diff_db"])
            if abs(rms_gap) > 1.0:
                issues.append(
                    "rain_light/rain_heavy: разница RMS %.2f dB больше 1 dB" % rms_gap
                )
        if asset["loop"] and isinstance(seam, float):
            if abs(seam) > float(asset["seam_limit_db"]):
                issues.append("%s: стык петли %+.2f dB, допустимо %.1f dB" % (
                    item["path"], seam, float(asset["seam_limit_db"])
                ))
    # Контрольное чтение с диска: проверяем именно то, что записалось.
    verify_ok, verify_issues, _rows = verify_assets(verbose=False)
    if not verify_ok:
        issues.extend(verify_issues)
    write_report(metrics_list, issues)
    print_rain_summary(metrics_list)
    return metrics_list, issues


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="Синтез аудиоассетов «Ночной смены»")
    parser.add_argument("--verify", action="store_true", help="только проверить готовые файлы")
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="пересобрать tools/t12_audio_report.txt по готовым файлам, без синтеза",
    )
    parser.add_argument("--quiet", action="store_true", help="не печатать таблицу")
    args = parser.parse_args(argv)

    if args.verify:
        ok, issues, _rows = verify_assets(verbose=not args.quiet)
        voice_count = len(collect_voice_wavs())
        if ok:
            print("VERIFY OK: %d сгенерированных файлов, пик %.1f dBFS и ниже; озвучка: %d файлов" % (
                len(collect_wavs()), PEAK_LIMIT_DBFS, voice_count
            ))
            return 0
        for issue in issues:
            print("VERIFY FAIL: " + issue)
        return 1

    if args.report_only:
        metrics_list = scan_metrics()
        ok, issues, _rows = verify_assets(verbose=not args.quiet)
        write_report(metrics_list, issues)
        print("REPORT: %s — файлов %d, проблем %d" % (REPORT_PATH, len(metrics_list), len(issues)))
        if ok:
            print("REPORT OK: %d файлов, пик %.1f dBFS и ниже" % (len(metrics_list), PEAK_LIMIT_DBFS))
            return 0
        for issue in issues:
            print("REPORT FAIL: " + issue)
        return 1

    print("Генерация ассетов в %s" % AUDIO_ROOT)
    metrics_list, issues = build_assets()
    print("")
    print("Готово: %d файлов, отчёт: %s" % (len(metrics_list), REPORT_PATH))
    if issues:
        for issue in issues:
            print("WARN: " + issue)
        return 1
    print("Все проверки пройдены: пик <= %.1f dBFS, петли склеены кроссфейдом." % PEAK_LIMIT_DBFS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
