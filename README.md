# Thermal Camera Probe

Two read-only tools that tell us whether a USB thermal camera (e.g. HIKMICRO
MiniE, InfiRay P2 Pro, FLIR ONE) can be read directly by EVITA, without the
maker's app. Whoever has the camera runs one or both and sends back the report.

Each ends with one of these verdicts:

| Code | Meaning |
|---|---|
| `DIRECT_WITH_TEMPERATURE` | Standard USB camera that appears to send temperature data. A native Android app can likely read it without an SDK. |
| `IMAGE_ONLY` | Opens like a webcam, but only as a picture. Live view is possible; temperatures need the maker's SDK. |
| `PROPRIETARY` | Vendor-specific USB device. Needs the maker's SDK. |
| `UVC_NOT_EXPOSED` / `NOT_VISIBLE` (web) | The tablet's browser can't see it. Run the Windows script to tell which case applies. |
| `INCONCLUSIVE` (Windows) | Camera not identified. Re-plug and run again, or use `-NoWizard`. |

## 1. Tablet: `camera-probe.html`

- Single file, no dependencies.
- Needs **HTTPS**, because Chrome only allows camera and USB access on secure pages.
- Host it on any static HTTPS host (Vercel, Netlify, GitHub Pages, or EVITA's own `public/` folder) and send the link.
- Opening the file directly from the tablet's Files app will **not** work.

Person with the camera:
1. Close the maker's app, then plug the camera into the tablet's USB-C port (tap Cancel if Android offers to open an app).
2. Open the link in **Chrome** and work through steps 1–4 on the page.
3. Tap **Download report** (and **Download captured frames**), then send the files.

What it checks:
- Android and Chrome versions, and whether camera and USB access are available.
- Every camera Chrome can open: delivered frame size, measured fps, supported sizes, and a captured frame.
- A frame analysis that spots the "picture on top, raw data below" pattern cheap thermal dongles use.
- The camera's USB identity and interface classes, if Chrome shows it in its USB device list. Chrome hides standard webcams there, so an empty list is a normal result.

To test locally: run `python -m http.server 8765` in this folder, then open http://127.0.0.1:8765/camera-probe.html (localhost counts as secure).

## 2. Windows PC: `camera-probe.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File .\camera-probe.ps1            # unplug/replug wizard (recommended)
powershell -ExecutionPolicy Bypass -File .\camera-probe.ps1 -NoWizard  # just list every USB/camera device
```

- Run it in **Windows PowerShell** (`powershell.exe`), not PowerShell 7.
- The wizard asks you to unplug and replug the camera, so it knows exactly which device is the camera.
- It reports the vendor and product ID, USB class, and Windows driver. `usbvideo` means a standard USB camera.
- It lists every video format the camera offers through the Windows camera API. Raw `Y16`/`L16` formats, or a frame twice as tall as the sensor, point to temperature data.
- If **ffmpeg** is installed (`winget install Gyan.FFmpeg`), it also saves one PNG and one raw native frame.
- Output goes to `Desktop\thermal-probe-<time>\` plus a `.zip` of it. Send the zip.

## 3. Mac: `camera-probe-mac.sh`

Use this when there is no Windows PC. Any Mac with a USB-C port works.

```bash
curl -fsSLO https://thermal-camera-probe.vercel.app/camera-probe-mac.sh
bash camera-probe-mac.sh               # unplug/replug wizard (recommended)
bash camera-probe-mac.sh --no-wizard   # just list USB devices and cameras
```

- Uses only tools built into macOS (`ioreg`, `system_profiler`, and AVFoundation through `osascript`). Nothing to install.
- Reports the vendor and product ID, USB interface classes, and every video format macOS offers (FourCC, size, fps). Raw greyscale formats (`L016`, `L008`) or a frame much taller than wide point to temperature data.
- If **ffmpeg** is installed (`brew install ffmpeg`), it also saves one PNG and one raw native frame. macOS may ask to let Terminal use the camera.
- Output goes to `Desktop/thermal-probe-<time>/` plus a `.zip` of it. Send the zip.
- Opening the web page (`camera-probe.html`) in Chrome on the same Mac also works. Chrome on macOS lists USB webcams, so it can capture and analyse a frame.

## Limits

- Both tools can show **whether** temperature data is there. Neither can confirm the readings are **accurate**. That needs a comparison against the maker's app on a target of known temperature.
- The browser converts every frame to 8-bit colour, so the web page can spot packed temperature data but cannot decode it. The raw frame from the Windows script (with ffmpeg) keeps the original bytes.
