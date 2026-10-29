"""Rebuild the agent-teams block of a DSH cordis.patch.yml from generator output.

Usage:
  python tools/patch_profiles.py --dry-run
  python tools/patch_profiles.py --write

The generator (tools/gen-agent-teams-profiles.mjs) is the only sanctioned source for
this block, so this script never invents content: it splices the generated block in
place of the stale one and reports exactly what changed.
"""

import argparse
import hashlib
import shutil
from pathlib import Path

PATCH = Path(r"C:\Users\Igor\.dsh\profiles\desktop\cordis.patch.yml")
GENERATED = Path(__file__).with_name("dsgs-profiles.yml")

START_MARK = "- id: agent-teams"


def split_patch(lines):
    start = next(i for i, line in enumerate(lines) if line.rstrip() == START_MARK)
    end = None
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("- id: "):
            end = i
            break
    if end is None:
        end = len(lines)
    return start, end


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    patch_text = PATCH.read_text(encoding="utf-8")
    gen_text = GENERATED.read_text(encoding="utf-8")
    patch_lines = patch_text.splitlines()
    gen_lines = gen_text.splitlines()

    gen_start = next(
        i for i, line in enumerate(gen_lines) if line.rstrip() == START_MARK
    )
    new_block = gen_lines[gen_start:]

    start, end = split_patch(patch_lines)
    old_block = patch_lines[start:end]
    head = patch_lines[:start]
    tail = patch_lines[end:]

    new_lines = head + new_block + tail
    new_text = "\n".join(new_lines) + "\n"

    print(f"patch: {PATCH} ({len(patch_lines)} lines)")
    print(f"old block: lines {start + 1}-{end} ({len(old_block)} lines)")
    print(f"new block: {len(new_block)} lines")
    print(f"result: {len(new_lines)} lines")
    print("anthropic in old:", "anthropic" in "\n".join(old_block))
    print("anthropic in new:", "anthropic" in new_text)
    print("model: lines new:", sum(1 for line in new_lines if line.strip().startswith("model:")))
    print("top-level ids new:", sum(1 for line in new_lines if line.startswith("- id: ")))
    print("sha256 old:", hashlib.sha256(patch_text.encode()).hexdigest()[:16])
    print("sha256 new:", hashlib.sha256(new_text.encode()).hexdigest()[:16])
    print("tail preserved:", tail == patch_lines[end:], "head preserved:", head == patch_lines[:start])

    if args.write:
        backup = PATCH.with_name(f"{PATCH.name}.bak-20261026")
        shutil.copy2(PATCH, backup)
        PATCH.write_text(new_text, encoding="utf-8")
        print("written; backup:", backup)
    else:
        print("dry run only (pass --write)")


if __name__ == "__main__":
    main()
