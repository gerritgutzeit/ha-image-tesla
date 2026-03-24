# RTSP Snapshot Viewer

Fullscreen live JPEG snapshots from an RTSP camera inside Home Assistant (Ingress). The page shows one image that updates on a schedule—**no video streaming** (no HLS, WebRTC, or in-browser video codecs).

## Why JPEG snapshots (e.g. Tesla browser)

This add-on was built so a camera can be checked from **browsers that do not support video** in a useful way—including the **Tesla in-car browser** when using Home Assistant there. The approach is to serve only **refreshed static JPEGs**, which any browser can display.

## Features

- **Configurable** RTSP URL and snapshot interval (add-on options)
- **Minimal fullscreen** page: black background, one image, scaled with `object-fit: contain`
- **Only the image reloads** (not the full page), with cache-busting
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

## Architecture

```text
RTSP camera  --TCP-->  ffmpeg (interval loop)  -->  /tmp/snapshot.jpg
                                                          |
                                                          v
                                               Python HTTP server :8099
                                                          |
                                                          v
                                               Home Assistant Ingress
```

## More information

- Repository and full readme: [ha-image-tesla on GitHub](https://github.com/gerritgutzeit/ha-image-tesla)
