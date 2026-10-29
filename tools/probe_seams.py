import json, os
import numpy as np
from PIL import Image
man = json.load(open("docs/art/pbr_manifest.json", encoding="utf-8"))
sets = man.get("sets", man)
for key, info in (sets.items() if isinstance(sets, dict) else []):
    if not isinstance(info, dict): continue
    path = info.get("diff") or info.get("diffuse") or info.get("files", {}).get("diff")
    if not isinstance(path, str): continue
    full = os.path.join(".", path) if not os.path.isabs(path) else path
    if not os.path.isfile(full): continue
    a = np.asarray(Image.open(full).convert("RGB"), dtype=np.float32) / 255.0
    interior = np.abs(a[:, 1:] - a[:, :-1]).mean()
    seam = np.abs(a[:, 0] - a[:, -1]).mean()
    vert_int = np.abs(a[1:] - a[:-1]).mean()
    vseam = np.abs(a[0] - a[-1]).mean()
    print(f"{key:12s} гориз. шов/внутрь = {seam:.4f}/{interior:.4f} ({seam/max(interior,1e-6):.2f}x)  верт. = {vseam:.4f}/{vert_int:.4f} ({vseam/max(vert_int,1e-6):.2f}x)")
