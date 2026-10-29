import json, urllib.request
def head(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent":"night-shift-probe"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.headers.get("Content-Length"), r.geturl()
for url in [
 "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip",
 "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx",
 "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx.json",
 "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/denis/medium/ru_RU-denis-medium.onnx",
]:
    try:
        st, ln, final = head(url)
        print(st, ln, final[:120])
    except Exception as e:
        print("ERR", url.split("/")[-1], type(e).__name__, e)
