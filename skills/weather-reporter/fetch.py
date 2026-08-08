import urllib.request
import sys

try:
    resp = urllib.request.urlopen("https://wttr.in/Taipei?format=3", timeout=5)
    print(resp.read().decode().strip())
except Exception as e:
    print(f"取得天氣失敗：{e}", file=sys.stderr)
    sys.exit(1)
