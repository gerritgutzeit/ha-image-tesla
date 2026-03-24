#!/command/with-contenv bashio

RTSP_URL=$(bashio::config 'rtsp_url')
INTERVAL=$(bashio::config 'interval')
# Slightly after each ffmpeg capture so the new JPEG is usually ready (same as 10s -> 10500 ms).
export REFRESH_MS=$((INTERVAL * 1000 + 500))

(
  while true; do
    ffmpeg -rtsp_transport tcp -y -i "$RTSP_URL" \
      -frames:v 1 -f image2 /tmp/snapshot_new.jpg 2>/dev/null \
      && mv /tmp/snapshot_new.jpg /tmp/snapshot.jpg
    sleep "$INTERVAL"
  done
) &

cat >/snapshot_server.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
import os

SNAPSHOT = "/tmp/snapshot.jpg"
PORT = 8099
REFRESH_MS = int(os.environ["REFRESH_MS"])

HTML = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RTSP Snapshot</title>
<style>
html, body {{ margin: 0; height: 100%; overflow: hidden; background: #000; }}
#cam {{ display: block; width: 100vw; height: 100vh; object-fit: contain; }}
</style>
</head>
<body>
<img id="cam" src="snapshot.jpg" alt="">
<script>
setInterval(() => {{
  const img = document.getElementById('cam');
  img.src = 'snapshot.jpg?t=' + Date.now();
}}, {REFRESH_MS});
</script>
</body>
</html>
"""


class SnapshotHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            data = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/snapshot.jpg":
            if not os.path.isfile(SNAPSHOT):
                body = b"Snapshot not yet available"
                self.send_response(503)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            with open(SNAPSHOT, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_error(404)


if __name__ == "__main__":
    HTTPServer(("", PORT), SnapshotHandler).serve_forever()
PY

exec python3 /snapshot_server.py
