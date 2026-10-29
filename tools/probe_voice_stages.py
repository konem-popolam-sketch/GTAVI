"""Stage-by-stage loudness probe for one voice profile (debug of t29 regen).

Renders a single line through tools/gen_voice_piper.py internals and prints RMS
after each stage, so a quiet character can be traced to a specific step.
"""

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_voice_piper as g  # noqa: E402


def rms(samples):
    return int(math.sqrt(float(np.mean(np.square(samples)))))


def main():
    speaker = sys.argv[1] if len(sys.argv) > 1 else "Прораб"
    text = sys.argv[2] if len(sys.argv) > 2 else "У тебя опоздание, Нил. Объяснись."
    profiles = dict(g.PROFILES)
    if speaker not in profiles:
        print("no such speaker:", speaker, list(profiles))
        return
    profile = profiles[speaker]
    print("profile:", profile.key if isinstance(profile.key, str) else profile.key())

    samples, rate = g.synth_raw(text, g.VOICES[profile.voice], profile.length_scale)
    print(f"raw        {samples.size / rate:5.2f}s peak={int(np.max(np.abs(samples))):5d} rms={rms(samples):5d}")

    body = g.trim_and_normalise(samples, rate)
    print(f"trim+norm  {body.size / rate:5.2f}s peak={int(np.max(np.abs(body))):5d} rms={rms(body):5d}")

    body = g.resample_linear(body, rate, g.TARGET_RATE)
    print(f"resample   {body.size / g.TARGET_RATE:5.2f}s peak={int(np.max(np.abs(body))):5d} rms={rms(body):5d}")

    body = g.pitch_shift(body, g.TARGET_RATE, profile.pitch)
    print(f"pitch      {body.size / g.TARGET_RATE:5.2f}s peak={int(np.max(np.abs(body))):5d} rms={rms(body):5d}")

    body = g.apply_effect(body, g.TARGET_RATE, profile.effect, 1)
    print(f"effect     {body.size / g.TARGET_RATE:5.2f}s peak={int(np.max(np.abs(body))):5d} rms={rms(body):5d}")

    body = g.limit_peak(body)
    print(f"limit      {body.size / g.TARGET_RATE:5.2f}s peak={int(np.max(np.abs(body))):5d} rms={rms(body):5d}")


if __name__ == "__main__":
    main()
