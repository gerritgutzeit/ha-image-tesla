# RTSP Snapshot Viewer

Fullscreen live JPEG snapshots from an RTSP camera inside Home Assistant (Ingress). The page shows one image that updates on a schedule—**no video streaming** (no HLS, WebRTC, or in-browser video codecs).

## Why JPEG snapshots (e.g. Tesla browser)

This add-on was built so a camera can be checked from **browsers that do not support video** in a useful way—including the **Tesla in-car browser** when using Home Assistant there. The approach is to serve only **refreshed static JPEGs**, which any browser can display.

## Features

- **Configurable** RTSP URL and snapshot interval (add-on options)
- **Minimal fullscreen** page: black background, one image, scaled with `object-fit: contain`
- **Smart refresh**: **Server-Sent Events** (`/events`) notify the browser when `snapshot.jpg` changes (mtime), so the JPEG is only re-fetched after a new frame—no blind timer downloads. **~250 ms** server-side check; SSE keepalive comments every **25 s**. If `EventSource` is missing or gets no event in **4 s**, the page falls back to the configured **interval-based** timer (Tesla-friendly).
- **503** response until the first frame exists: `Snapshot not yet available`
- **ffmpeg** uses **RTSP over TCP** (`-rtsp_transport tcp`) for reliable camera connections
- **Atomic updates**: writes `snapshot_new.jpg`, then renames to `snapshot.jpg` so partial files are not served

## Installation

### Custom repository (public GitHub repo)

1. **Settings** → **Add-ons** → **Add-on store** → **⋮** → **Repositories**
2. Add: `https://github.com/gerritgutzeit/ha-image-tesla`
3. Install **RTSP Snapshot Viewer**, then **Start**

Private repositories cannot be cloned by the Supervisor without credentials. Use a **local add-on** copy instead, or make the repository public.

### Local add-on

1. Copy the folder `rtsp_snapshot_viewer` into your Home Assistant **addons** share (folder name must match the add-on slug).
2. **Check for updates** in the add-on store (or restart Supervisor). The add-on appears under **Local add-ons**.

## Configuration

| Option      | Description |
|------------|-------------|
| `rtsp_url` | Full RTSP URL, e.g. `rtsp://user:password@192.168.1.50:554/stream1` |
| `interval` | Target **seconds between the start** of each capture (1–86400). The loop **subtracts** ffmpeg run time so e.g. `1` aims for ~one frame per second when the camera and network keep up. The web UI refresh uses a small extra buffer (100 ms at 1 s, up to 500 ms at longer intervals). |

**Tapo C200 (example)**

- HD: `rtsp://USER:PASS@CAMERA_IP:554/stream1`
- SD: `rtsp://USER:PASS@CAMERA_IP:554/stream2`

Keep credentials in **Home Assistant add-on options**, not in git.

**Test ffmpeg on any machine with ffmpeg:**

```bash
ffmpeg -rtsp_transport tcp -y -i "rtsp://USER:PASS@IP:554/stream1" -frames:v 1 /tmp/test.jpg
```

## After installation

1. Open the add-on and click **Start**.
2. Enable **Show in sidebar** for a fullscreen Ingress panel.
3. Use **Open web UI** to open the viewer.

## Expose on your LAN / reverse proxy (e.g. Nginx Proxy Manager)

Ingress only reaches the app **through Home Assistant**. To use **Nginx Proxy Manager** (or any reverse proxy) on the same network, the add-on must also listen on a **host port**.

1. Open the add-on → **Configuration** (or **Network**, depending on your HA version).
2. Under **Network** / **Port mapping**, set **8099/tcp** to a host port (often **8099**, or another free port). Save and restart the add-on if prompted.
3. Check from a PC: `http://<Home_Assistant_IP>:8099/` (use the port you mapped). You should see the same page as Ingress.

**Nginx Proxy Manager**

- For **live updates** through NPM, SSE must not be buffered: **Nginx Proxy Manager** → your proxy host → **Advanced** → custom Nginx configuration, e.g. `proxy_buffering off;` and `proxy_cache off;` (or the equivalent for your setup). Without this, the page may fall back to timer polling after a few seconds.

- **Details** → **Domain names**: e.g. `cam.example.com` (use a **subdomain** at the **root path** `/` — the page uses relative `snapshot.jpg` URLs, so path-prefix proxies need extra NPM rules).
- **Scheme**: `http`
- **Forward hostname / IP**: your **Home Assistant host’s LAN IP** (the machine running Supervisor), e.g. `192.168.1.50`
- **Forward port**: the **host** port you mapped (e.g. `8099`)
- **Block common exploits**: on
- **Websockets support**: optional (this add-on does not need it for snapshots)

If NPM runs **on the same HA OS machine**, forwarding to the **HA LAN IP** and mapped port is usually enough. If NPM runs elsewhere, use an IP/firewall rule that can reach that host port.

**Security (important)**

The built-in server has **no login**. Anyone who can open the URL sees your camera snapshots. Prefer **NPM Access Lists**, **HTTP Basic Auth**, **Authelia**, **Cloudflare Access**, **VPN-only** reachability, or keep the port **disabled** and use Ingress only.

## Architecture

```text
RTSP camera  --TCP-->  ffmpeg (interval loop)  -->  /tmp/snapshot.jpg
                                                          |
                                                          v
                                               Python HTTP server :8099
                                                          |
                                    +---------------------+---------------------+
                                    |                                           |
                                    v                                           v
                          Home Assistant Ingress              Optional host port
                                                          (LAN / reverse proxy)
```

## More information

- Repository and full readme: [ha-image-tesla on GitHub](https://github.com/gerritgutzeit/ha-image-tesla)
