import time, urllib.request
tests = {
 "ambientcg_api": "https://ambientcg.com/api/v2/full_json?type=Material&limit=2",
 "ambientcg_zip": "https://ambientcg.com/get?file=Asphalt012_2K-JPG.zip",
 "github_raw": "https://raw.githubusercontent.com/godotengine/godot/master/README.md",
 "kenney_github": "https://github.com/KenneyNL/Starter-Kit-3D-Platformer",
}
for name,url in tests.items():
    t=time.time()
    try:
        req=urllib.request.Request(url, headers={"User-Agent":"night-shift/1.0"})
        with urllib.request.urlopen(req, timeout=25) as r:
            data=r.read(200000)
        print(f"{name}: OK {r.status} {len(data)} bytes {time.time()-t:.1f}s")
    except Exception as e:
        print(f"{name}: ERR {type(e).__name__} {str(e)[:80]} {time.time()-t:.1f}s")
