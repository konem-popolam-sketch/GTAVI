"""Download the offline neural TTS stack: piper binary plus Russian voices.

The sandbox blocks SAPI file output (`0x80045040`), and edge-tts cannot keep its
websocket alive through this network path, so voice-over is produced locally by
piper (ONNX, espeak-ng phonemes). Everything lands under tools/piper/.
"""

import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIPER_DIR = ROOT / "tools" / "piper"
VOICE_DIR = PIPER_DIR / "voices"

BINARY_URL = (
    "https://github.com/rhasspy/piper/releases/download/"
    "2023.11.14-2/piper_windows_amd64.zip"
)

VOICES = {
    "ru_RU-irina-medium": [
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        "ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx",
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        "ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx.json",
    ],
    "ru_RU-denis-medium": [
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        "ru/ru_RU/denis/medium/ru_RU-denis-medium.onnx",
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        "ru/ru_RU/denis/medium/ru_RU-denis-medium.onnx.json",
    ],
}

UA = {"User-Agent": "night-shift-tts/1.0"}


def download(url, dest: Path, force=False):
    if dest.exists() and dest.stat().st_size > 0 and not force:
        print(f"[skip] {dest.name} ({dest.stat().st_size} B)")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as resp, tmp.open("wb") as out:
        total = 0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            total += len(chunk)
    tmp.replace(dest)
    print(f"[get] {dest.name} {total / 1e6:.1f} MB")


def main():
    force = "--force" in sys.argv
    zip_path = PIPER_DIR / "piper_windows_amd64.zip"
    download(BINARY_URL, zip_path, force)
    exe = PIPER_DIR / "piper" / "piper.exe"
    if force or not exe.exists():
        print("[unzip] piper_windows_amd64.zip")
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(PIPER_DIR)
    else:
        print("[skip] piper.exe already unpacked")

    for name, urls in VOICES.items():
        for url in urls:
            download(url, VOICE_DIR / url.rsplit("/", 1)[-1], force)

    print("\n[result]")
    print("  exe    ", exe, exe.exists())
    for name in VOICES:
        onnx = VOICE_DIR / f"{name}.onnx"
        cfg = VOICE_DIR / f"{name}.onnx.json"
        print(f"  {name}: onnx={onnx.stat().st_size if onnx.exists() else 0} B,"
              f" cfg={cfg.exists()}")


if __name__ == "__main__":
    main()
