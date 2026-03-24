# ha-image-tesla

<p align="center">
  <strong>RTSP Snapshot Viewer</strong><br />
  <sub>Home Assistant add-on · fullscreen JPEG snapshots from any RTSP camera · Ingress-ready</sub>
</p>

<p align="center">
  <a href="https://github.com/gerritgutzeit/ha-image-tesla"><img src="https://img.shields.io/github/stars/gerritgutzeit/ha-image-tesla?style=flat-square&logo=github" alt="GitHub stars" /></a>
</p>

---

## What this is

This repository hosts a **Home Assistant Supervisor add-on** that shows a **single live-updating JPEG** from an **RTSP** stream inside the Home Assistant UI (Ingress). It does **not** stream video in the browser: only periodic still images, so it works even where video playback is limited.

### Why it was built (Tesla browser)

The original goal was to **check a camera feed from the Tesla in-car web browser** while opening Home Assistant there. That environment **does not support video** in a useful way for typical camera streams (no practical HLS, WebRTC, or normal in-browser video for this use case). The practical conclusion was to **avoid video entirely** and serve only **refreshed static JPEGs**—which any browser can display—so the same Ingress page works in the Tesla browser as well as on a phone or desktop.

| Goal | How |
|------|-----|
| Stable camera compatibility | `ffmpeg` with **RTSP over TCP** (`-rtsp_transport tcp`) |
| No torn frames on refresh | Write `snapshot_new.jpg`, then **rename** to `snapshot.jpg` |
| Fits the HA sidebar | **Ingress** + optional **Show in sidebar** |

---

## Features

- **Configurable RTSP URL** and **snapshot interval** (add-on options)
- **Minimal fullscreen page**: black background, one image, `object-fit: contain`
- **Browser reloads only the image** (not the whole page), with cache-busting
- **503** until the first frame exists (`Snapshot not yet available`)
- **Multi-arch** builds: `aarch64`, `amd64`, `armhf`, `armv7`

---

## Installation

### Option A — Custom repository (public repo)

1. In Home Assistant: **Settings → Add-ons → Add-on store** → **⋮ → Repositories**
2. Add: `https://github.com/gerritgutzeit/ha-image-tesla`
3. Install **RTSP Snapshot Viewer**, then **Start**

Private GitHub repositories cannot be cloned by the Supervisor without credentials. Use **Option B** or make the repository public.

### Option B — Local add-on (private repo or development)

1. Copy the folder `rtsp_snapshot_viewer` into your Home Assistant **`addons`** share (same name as `slug`).
2. **Check for updates** in the add-on store (or restart Supervisor). The add-on appears under **Local add-ons**.

---

## Configuration

| Option | Description |
|--------|-------------|
| `rtsp_url` | Full RTSP URL, e.g. `rtsp://user:password@192.168.1.50:554/stream1` |
| `interval` | Target seconds **between capture starts** (1–86400). Elapsed ffmpeg time is subtracted so low values (e.g. `1`) aim for ~1 frame/s; the page refresh buffer scales (about +100 ms at 1 s, up to +500 ms at 10 s). |

**Tapo C200 (example):**

- HD: `rtsp://USER:PASS@CAMERA_IP:554/stream1`
- SD: `…/stream2`

**Manual ffmpeg test (on any machine with ffmpeg):**

```bash
ffmpeg -rtsp_transport tcp -y -i "rtsp://USER:PASS@IP:554/stream1" -frames:v 1 /tmp/test.jpg
```

Credentials live in **Home Assistant add-on options**, not in this git repository.

---

## After install

1. Open the add-on → **Start**
2. Turn on **Show in sidebar** for a fullscreen Ingress panel
3. Use **Open web UI** to open the viewer

### Nginx Proxy Manager / LAN access

The add-on can **publish port 8099** to the Home Assistant host (see **Network** on the add-on page). Then you can point NPM at `http://<HA_LAN_IP>:8099` with a dedicated subdomain. The viewer uses **relative** image URLs, so prefer **`/` at the root** of that host (not a subpath like `/camera/` without extra proxy rules). The Python server has **no authentication**—protect it at the proxy (access lists, VPN, etc.). Details: [DOCS.md](rtsp_snapshot_viewer/DOCS.md).

---

## Architecture

```text
[ RTSP camera ] --TCP--> ffmpeg (interval loop) --> /tmp/snapshot.jpg
                                                              |
                                                              v
                                                    Python http.server :8099
                                                              |
                                                              v
                                                    Home Assistant Ingress
```

---

## Repository layout

```text
ha-image-tesla/
├── repository.yaml              # Custom add-on repository metadata (for the HA store)
├── README.md                    # This file
└── rtsp_snapshot_viewer/       # Add-on (directory name = slug)
    ├── config.yaml
    ├── build.yaml
    ├── Dockerfile
    ├── DOCS.md                   # Shown in HA add-on “Documentation” tab
    └── run.sh
```

---

## GitHub “About” box (suggested short description)

> HA add-on: RTSP camera as refreshed JPEGs (Tesla browser–friendly; no video codecs) via Ingress.

---
