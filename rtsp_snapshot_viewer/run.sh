#!/command/with-contenv bashio

OPTIONS_FILE="/data/options.json"
INTERVAL=$(bashio::config 'interval')
[ "${INTERVAL:-1}" -lt 1 ] && INTERVAL=1
export INTERVAL

# Browser poll: interval + buffer. Buffer scales down for short intervals (1s -> +100 ms, 10s -> +500 ms).
EXTRA_MS=$((INTERVAL * 100))
[ "$EXTRA_MS" -gt 500 ] && EXTRA_MS=500
export REFRESH_MS=$((INTERVAL * 1000 + EXTRA_MS))

_sync_selection_from_options() {
  python3 -c "
import json
try:
    with open('${OPTIONS_FILE}') as f:
        o = json.load(f)
except Exception:
    o = {}

def cameras(o):
    c = o.get('cameras')
    if isinstance(c, list) and c:
        return [x for x in c if isinstance(x, dict) and (str(x.get('url') or '').strip())]
    u = (o.get('rtsp_url') or '').strip()
    return [{'name': 'Camera', 'url': u}] if u else []

cams = cameras(o)
active = (o.get('active_camera') or '').strip()
names = [str(c.get('name') or '').strip() for c in cams if str(c.get('name') or '').strip()]
if not cams:
    open('/tmp/selected_camera', 'w').close()
elif active and any(str(c.get('name') or '').strip() == active for c in cams):
    open('/tmp/selected_camera', 'w').write(active)
elif names:
    open('/tmp/selected_camera', 'w').write(names[0])
else:
    open('/tmp/selected_camera', 'w').write('Camera')
"
}

_sync_selection_from_options

(
  while true; do
    SNAP_T0=$(python3 -c "import time; print(time.time())")
    export SNAP_T0
    RTSP_URL=$(python3 <<'RESOLVE'
import json
try:
    with open("/data/options.json") as f:
        o = json.load(f)
except Exception:
    o = {}

def cameras(o):
    c = o.get("cameras")
    if isinstance(c, list) and c:
        return [x for x in c if isinstance(x, dict) and (str(x.get("url") or "").strip())]
    u = (o.get("rtsp_url") or "").strip()
    return [{"name": "Camera", "url": u}] if u else []

cams = cameras(o)
try:
    sel = open("/tmp/selected_camera").read().strip()
except Exception:
    sel = ""
url = ""
for c in cams:
    if str(c.get("name") or "").strip() == sel:
        url = str(c.get("url") or "").strip()
        break
if not url and cams:
    url = str(cams[0].get("url") or "").strip()
print(url)
RESOLVE
)
    if [ -z "$RTSP_URL" ]; then
      python3 -c "
import os, time
interval = float(os.environ['INTERVAL'])
start = float(os.environ['SNAP_T0'])
remain = max(0.0, interval - (time.time() - start))
time.sleep(remain)
"
      continue
    fi
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
from urllib.parse import parse_qs, urlparse
import html
import json
import os
import queue
import threading
import time
from typing import Any, Dict, List, Optional

SNAPSHOT = "/tmp/snapshot.jpg"
OPTIONS_FILE = "/data/options.json"
STATE_FILE = "/tmp/selected_camera"
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


def _load_options() -> Dict[str, Any]:
    try:
        with open(OPTIONS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _cameras_list(o: Dict[str, Any]) -> List[Dict[str, str]]:
    c = o.get("cameras")
    if isinstance(c, list) and c:
        out: List[Dict[str, str]] = []
        for x in c:
            if not isinstance(x, dict):
                continue
            url = str(x.get("url") or "").strip()
            if not url:
                continue
            name = str(x.get("name") or "").strip() or "Camera"
            out.append({"name": name, "url": url})
        return out
    u = str(o.get("rtsp_url") or "").strip()
    if u:
        return [{"name": "Camera", "url": u}]
    return []


def _current_selection(cams: List[Dict[str, str]]) -> str:
    names = [c["name"] for c in cams]
    try:
        sel = open(STATE_FILE).read().strip()
    except Exception:
        sel = ""
    if sel and sel in names:
        return sel
    if names:
        return names[0]
    return ""


def _html_page() -> str:
    o = _load_options()
    cams = _cameras_list(o)
    sel = _current_selection(cams)
    if cams:
        opts = []
        for c in cams:
            n = c["name"]
            s = " selected" if n == sel else ""
            opts.append(
                f'<option value="{html.escape(n)}"{s}>{html.escape(n)}</option>'
            )
        options_html = "\n".join(opts)
        body = f"""<div id="bar">
<label for="camsel">Camera</label>
<select id="camsel" aria-label="Camera">{options_html}</select>
</div>
<img id="cam" src="snapshot.jpg" alt="">"""
    else:
        body = '<p id="empty">No cameras configured. Add named streams in the add-on options.</p>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RTSP Snapshot</title>
<style>
html, body {{ margin: 0; height: 100%; overflow: hidden; background: #000; }}
#bar {{
  position: fixed; top: 0; left: 0; right: 0; z-index: 10;
  display: flex; align-items: center; gap: 0.5rem;
  padding: 0.5rem 0.75rem; background: rgba(0,0,0,0.72);
  font: 14px system-ui, sans-serif; color: #ccc;
}}
#bar label {{ flex-shrink: 0; }}
#camsel {{
  min-width: 8rem; max-width: 100%; padding: 0.25rem 0.5rem;
  background: #222; color: #eee; border: 1px solid #444; border-radius: 4px;
}}
#cam {{ display: block; width: 100vw; margin-top: 2.75rem; height: calc(100vh - 2.75rem); object-fit: contain; }}
#empty {{ margin: 0; padding: 2rem; color: #888; font: 16px system-ui, sans-serif; }}
</style>
</head>
<body>
{body}
<script>
(function() {{
  const img = document.getElementById('cam');
  const sel = document.getElementById('camsel');
  function bump(t) {{
    if (img) img.src = 'snapshot.jpg?t=' + t;
  }}
  if (sel) {{
    sel.addEventListener('change', function() {{
      const v = this.value;
      fetch('select?name=' + encodeURIComponent(v), {{ method: 'GET', cache: 'no-store' }})
        .then(function() {{ bump(Date.now()); }});
    }});
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
            data = _html_page().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/select":
            qs = parse_qs(urlparse(self.path).query)
            raw = (qs.get("name") or [""])[0]
            name = raw.strip()
            cams = _cameras_list(_load_options())
            names = {c["name"] for c in cams}
            if not name or name not in names:
                self.send_error(400)
                return
            try:
                with open(STATE_FILE, "w") as f:
                    f.write(name)
            except OSError:
                self.send_error(500)
                return
            self.send_response(204)
            self.end_headers()
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
