import json, urllib.request
def get(u):
    r=urllib.request.Request(u, headers={"User-Agent":"night-shift-probe"})
    return json.loads(urllib.request.urlopen(r, timeout=45).read().decode())
d=get("https://api.polyhaven.com/assets?t=textures&c=asphalt")
print("asphalt ids:", len(d))
for k in list(d)[:12]:
    files=get(f"https://api.polyhaven.com/files/{k}")
    has=files.get("Diffuse") or files.get("diffuse") or files.get("diff")
    maps=[m for m in ("Diffuse","diffuse","nor_gl","nor_dx","Rough","rough","AO","ao","Displacement","displacement") if m in files]
    print(k, "maps:", maps)
