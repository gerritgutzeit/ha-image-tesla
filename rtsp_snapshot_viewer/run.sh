#!/command/with-contenv bashio

RTSP_URL=$(bashio::config 'rtsp_url')
INTERVAL=$(bashio::config 'interval')
[ "${INTERVAL:-1}" -lt 1 ] && INTERVAL=1
export INTERVAL

# Browser poll: interval + buffer. Buffer scales down for short intervals (1s -> +100 ms, 10s -> +500 ms).
EXTRA_MS=$((INTERVAL * 100))
[ "$EXTRA_MS" -gt 500 ] && EXTRA_MS=500
export REFRESH_MS=$((INTERVAL * 1000 + EXTRA_MS))

(
  while true; do
    SNAP_T0=$(python3 -c "import time; print(time.time())")
    export SNAP_T0
    ffmpeg -hide_banner -loglevel error -rtsp_transport tcp \
      -an -fflags nobuffer -flags low_delay \
      -y -i "$RTSP_URL" \
      -frames:v 1 -f image2 /tmp/snapshot_new.jpg 2>/dev/null \
      && mv /tmp/snapshot_new.jpg /tmp/snapshot.jpg
    python3 -c "
import os, time
interval = float(os.environ['INTERVAL'])
start = float(os.environ['SNAP_T0'])
remain = max(0.0, interval - (time.time() - start))
time.sleep(remain)
"
  done
) &

cat >/snapshot_server.py <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
import os
import queue
import threading
import time
from typing import List, Optional

SNAPSHOT = "/tmp/snapshot.jpg"
PORT = 8099
REFRESH_MS = int(os.environ["REFRESH_MS"])


class Broadcaster:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._clients: List[queue.Queue] = []

    def subscribe(self) -> queue.Queue:
        q = queue.Queue(maxsize=4)
        with self._lock:
            self._clients.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            try:
                self._clients.remove(q)
            except ValueError:
                pass

    def publish(self, mtime: float) -> None:
        with self._lock:
            for q in self._clients:
                try:
                    q.put_nowait(mtime)
                except queue.Full:
                    try:
                        q.get_nowait()
                    except queue.Empty:
                        pass
                    try:
                        q.put_nowait(mtime)
                    except queue.Full:
                        pass


broadcaster = Broadcaster()


def _watch_snapshots() -> None:
    last: Optional[float] = None
    if os.path.isfile(SNAPSHOT):
        try:
            last = os.path.getmtime(SNAPSHOT)
        except OSError:
            last = None
    while True:
        time.sleep(0.25)
        if not os.path.isfile(SNAPSHOT):
            continue
        try:
            m = os.path.getmtime(SNAPSHOT)
        except OSError:
            continue
        if last is None or m != last:
            last = m
            broadcaster.publish(m)


threading.Thread(target=_watch_snapshots, daemon=True).start()

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
(function() {{
  const img = document.getElementById('cam');
  function bump(t) {{
    img.src = 'snapshot.jpg?t=' + t;
  }}
  if (typeof EventSource !== 'undefined') {{
    let sseOk = false;
    const es = new EventSource('events');
    es.onmessage = function(e) {{ sseOk = true; bump(e.data); }};
    setTimeout(function() {{
      if (!sseOk) {{
        es.close();
        setInterval(function() {{ bump(Date.now()); }}, {REFRESH_MS});
      }}
    }}, 4000);
  }} else {{
    setInterval(function() {{ bump(Date.now()); }}, {REFRESH_MS});
  }}
}})();
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
        if path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            q = broadcaster.subscribe()
            try:
                if os.path.isfile(SNAPSHOT):
                    try:
                        m = os.path.getmtime(SNAPSHOT)
                        self.wfile.write(f"data: {m}\n\n".encode())
                        self.wfile.flush()
                    except OSError:
                        pass
                while True:
                    try:
                        m = q.get(timeout=25.0)
                    except queue.Empty:
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
                        continue
                    self.wfile.write(f"data: {m}\n\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            finally:
                broadcaster.unsubscribe(q)
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


def _startup_banner() -> None:
    print(
        r"""
    .--.      .--.      .--.      .--.
   |    |    |    |    |    |    |    |
    '--'      '--'      '--'      '--'
  ___________________________________________
 |                                           |
 |      RTSP Snapshot Viewer is active       |
 |              (port %d)                    |
 |___________________________________________|
"""
        % PORT,
        flush=True,
    )


if __name__ == "__main__":
    _startup_banner()
    ThreadingHTTPServer(("", PORT), SnapshotHandler).serve_forever()
PY

exec python3 /snapshot_server.py
