# Sets each demo file's modification date from demo/manifest.json, so the demo looks like a
# real home folder: most things months or years old, one draft from this morning. Git doesn't
# keep modification dates, so run this after cloning and before `Appears -demo`.
#
#   python3 -I demo/set-ages.py
import json
import os
import time
from pathlib import Path

root = Path(__file__).resolve().parent
ages = json.loads((root / "manifest.json").read_text())["ages"]
now = time.time()
for path, days in ages.items():
    target = root / "files" / path
    stamp = now - days * 86400
    os.utime(target, (stamp, stamp))
print(f"set {len(ages)} modification dates")
