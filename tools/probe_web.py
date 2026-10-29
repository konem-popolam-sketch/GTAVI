import re
import urllib.request

BASE = "http://127.0.0.1:63625"


def get(path, timeout=8):
    try:
        r = urllib.request.urlopen(BASE + path, timeout=timeout)
        return r.status, r.read()
    except Exception as exc:  # noqa: BLE001
        return None, str(exc).encode()


status, body = get("/")
text = body.decode("utf-8", "replace") if status else str(body)
print("root:", status, "len", len(text))
print("srcs:", re.findall(r'(?:src|href)="([^"]+)"', text)[:25])
print("roster mention:", "roster" in text)

for path in [
    "/plugins/dsgs-agent-roster/state",
    "/api/plugins/dsgs-agent-roster/state",
    "/plugin/dsgs-agent-roster/state",
    "/dsgs-agent-roster/state",
]:
    st, _ = get(path)
    print(path, st)
