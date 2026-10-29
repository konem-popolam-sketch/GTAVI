import json, urllib.request
def get(u):
    r=urllib.request.Request(u, headers={"User-Agent":"night-shift-probe"})
    return json.loads(urllib.request.urlopen(r, timeout=45).read().decode())
tex=get("https://api.polyhaven.com/assets?t=textures")
def maps(i):
    try: f=get(f"https://api.polyhaven.com/files/{i}")
    except Exception: return []
    return [m for m in ("Diffuse","nor_gl","Rough","AO") if m in f]
def pick(sub, n=4):
    out=[]
    for k in tex:
        if sub in k.lower():
            m=maps(k)
            if len(m)==4: out.append(k)
        if len(out)>=n: break
    return out
for sub in ["brick","roof","plank","plaster","concrete","metal","asphalt","cobble"]:
    print(sub, "->", pick(sub))
mdl=get("https://api.polyhaven.com/assets?t=models")
def pickm(sub,n=5):
    return [k for k in mdl if sub in k.lower()][:n]
for sub in ["crate","barrel","cone","bench","fence","sign","bollard","trash","dumpster","pallet","pipe","ladder"]:
    print(sub, "->", pickm(sub))
