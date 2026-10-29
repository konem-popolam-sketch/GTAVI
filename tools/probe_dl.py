import json, time, urllib.request
def head(url):
    req = urllib.request.Request(url, headers={"User-Agent": "night-shift/1.0"}, method="HEAD")
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, r.headers.get("Content-Length"), round(time.time()-t0, 2)

tests = [
 "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/asphalt_02/asphalt_02_diff_2k.jpg",
 "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/asphalt_02/asphalt_02_nor_gl_2k.jpg",
 "https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/street_lamp_01/street_lamp_01_1k.gltf",
 "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/venice_sunset_1k.hdr",
]
for u in tests:
    try:
        print(head(u), u.rsplit("/",1)[-1])
    except Exception as e:
        print("FAIL", type(e).__name__, e, u.rsplit("/",1)[-1])

# list a few model ids
req = urllib.request.Request("https://api.polyhaven.com/assets?t=models", headers={"User-Agent":"night-shift/1.0"})
items = json.loads(urllib.request.urlopen(req, timeout=30).read())
print("models:", len(items))
names = sorted(items)[:15]
print(names)
