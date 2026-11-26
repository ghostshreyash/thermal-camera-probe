# Thermal camera probe: notes for Claude Code

Read-only diagnostic tools that show whether a USB thermal camera can be read
directly, without the maker's app or SDK. They were built for the HIKMICRO
MiniE (VID `0x2BDF`, PID `0x0102`) used by EVITA. See `README.md` for how to run
each tool.

- `camera-probe.html`: one self-contained page with no build step. It needs
  HTTPS or localhost (`python -m http.server 8765`).
- `camera-probe.ps1`: **Windows PowerShell 5.1**, not PowerShell 7. Optional
  ffmpeg.
- `camera-probe-mac.sh`: macOS built-in tools only, so **bash 3.2**: no
  heredocs inside `$(...)` and no bash 4 features. **LF line endings only**
  (`.gitattributes` enforces this).
- `vercel.json`: routes `/` → the page, `/mac` → the Mac script, `/mac-guide`
  → the guide.

**Deploying.** Live at https://thermal-camera-probe.vercel.app, on Shreyash's
personal Vercel account. It is **not** git-connected, so a push does not
deploy. Run `npx vercel deploy --prod` with access to that project.

**What is known about the MiniE, and the app that reads it,** is in
`CLAUDE.md` of the `evita-frontend` repo (vDoIT-Technologies), on the branch
`capacitor-android`, in the section "Thermal camera probe tools". In short:

- standard UVC with a bulk endpoint;
- yuyv422 at 96×100, 96×176, 96×194, 96×216 and 96×322, plus nv12 96×96;
- the 96×96 raw thermal block (16-bit LE, higher = hotter) starts at word
  `143*96+68` in 96×322 and at word `0` in 96×176;
- Windows cannot start 96×322 but streams 96×176;
- °C calibration is still pending.

When capturing by hand:
- keep the bytes exact with `-c:v copy -f rawvideo`;
- pick the camera by name (`"UVC Camera"`), never by index;
- never Ctrl+C a stuck ffmpeg. Close the window and replug the camera.
