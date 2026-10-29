import json, urllib.request
def get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": "night-shift/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()

for url in ["https://api.polyhaven.com/assets?t=models&c=street",
            "https://api.polyhaven.com/assets?t=textures&c=asphalt"]:
    try:
        st, data = get(url)
        items = json.loads(data)
        print(url, "->", st, "items", len(items))
        for name in list(items)[:8]:
            print("   ", name, items[name].get("name"), items[name].get("categories"))
    except Exception as exc:
        print(url, "FAILED:", type(exc).__name__, exc)
