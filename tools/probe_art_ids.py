import json, urllib.request
def get(u):
    r=urllib.request.Request(u, headers={"User-Agent":"night-shift-probe"})
    return json.loads(urllib.request.urlopen(r, timeout=45).read().decode())
tex=get("https://api.polyhaven.com/assets?t=textures")
mdl=get("https://api.polyhaven.com/assets?t=models")
def check_tex(i):
    try:
        f=get(f"https://api.polyhaven.com/files/{i}")
    except Exception: return None
    return [m for m in ("Diffuse","nor_gl","Rough","AO") if m in f]
def find_tex(words, exclude):
    hits=[]
    for k,v in tex.items():
        name=k.lower(); cats=" ".join(v.get("categories",[])).lower()
        if any(w in name or w in cats for w in words) and not any(e in name for e in exclude):
            hits.append(k)
    return hits[:6]
tex_ids=["asphalt_02","asphalt_04","asphalt_01","red_brick_02","red_brick_01","brick_wall_001","brick_wall_007","brick_wall_002","brick_wall_004","concrete_wall_008","concrete_02","concrete_wall_004","beige_wall_001","plaster_02","stucco_02","metal_plate_02","metal_plate","corrugated_iron_02","wood_planks_02","wood_planks","plank_flooring_02","roof_tiles_02","shingle_02","roofing_02"]
for i in tex_ids:
    maps=check_tex(i)
    print(("OK " if maps else "BAD"), i, maps or "")
print("--- suggestions ---")
for words,excl in [(["asphalt"],["snow","wet","puddle"]),(["brick","red"],["grey","white"]),(["brick"],["red","white"]),(["concrete"],["ceiling"]),(["plaster","stucco"],["brick"]),(["metal","plate"],["gold"]),(["wood","plank"],["parquet"]),(["roof","tile"],["thatch"])]:
    print(words, "->", find_tex(words,excl))
print("--- models ---")
for k in ["wooden_crate_01","wooden_crate_02","crate","metal_barrel_01","barrel_01","trash_container","street_lamp_01","traffic_cone","bench_01","fence_01","sign_01","bollard_01"]:
    print(("OK " if k in mdl else "BAD"), k)
