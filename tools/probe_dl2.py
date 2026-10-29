import time, urllib.request
url="https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/asphalt_01/asphalt_01_diff_2k.jpg"
for attempt in range(3):
    t=time.time()
    try:
        req=urllib.request.Request(url, headers={"User-Agent":"night-shift/1.0"})
        with urllib.request.urlopen(req, timeout=300) as r:
            total=0
            while True:
                c=r.read(1<<18)
                if not c: break
                total+=len(c)
                if total>0 and time.time()-t>60: break
        print(f"attempt {attempt+1}: {total} bytes in {time.time()-t:.1f}s")
        if total>1_000_000: break
    except Exception as e:
        print(f"attempt {attempt+1}: ERR {type(e).__name__} {e} after {time.time()-t:.1f}s")
