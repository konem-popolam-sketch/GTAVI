"""Compare raw piper output loudness across the four Russian voices.

Used to tell whether a quiet character is a piper model problem or a
post-processing bug in tools/gen_voice_piper.py.
"""

import math
import struct
import subprocess
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPER = ROOT / "tools" / "piper" / "piper" / "piper.exe"
TEXT = "Проверка голоса прораба, раз два три."


def stats(path):
    with wave.open(str(path)) as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        samples = struct.unpack("<%dh" % frames, handle.readframes(frames))
    rms = int(math.sqrt(sum(x * x for x in samples) / max(frames, 1)))
    return frames / rate, max(abs(x) for x in samples), rms


def main():
    for voice in ("ruslan", "dmitri", "irina", "denis"):
        model = ROOT / "tools" / "piper" / "voices" / f"ru_RU-{voice}-medium.onnx"
        out = ROOT / "tools" / f"_v_{voice}.wav"
        proc = subprocess.run(
            [str(PIPER), "--model", str(model), "--output_file", str(out)],
            input=TEXT.encode("utf-8"),
            capture_output=True,
        )
        duration, peak, rms = stats(out)
        err = proc.stderr.decode("utf-8", "ignore")[:120].replace("\n", " ")
        print(f"{voice:7s} {duration:5.2f}s peak={peak:5d} rms={rms:5d} rc={proc.returncode} {err}")


if __name__ == "__main__":
    main()
