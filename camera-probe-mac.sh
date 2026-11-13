#!/bin/bash
#
# Thermal camera probe for macOS.
#
# Read-only check of a USB thermal camera (e.g. HIKMICRO MiniE) on a Mac. It
# reports the camera's USB identity, the video formats macOS offers, and a
# verdict on whether EVITA could read it directly. It changes nothing.
#
# Usage (in Terminal):
#   bash camera-probe-mac.sh               unplug/replug wizard (recommended)
#   bash camera-probe-mac.sh --no-wizard   just list USB devices and cameras
#   bash camera-probe-mac.sh --out DIR     save somewhere other than the Desktop
#
# With ffmpeg installed (brew install ffmpeg) it also saves one PNG frame and
# ten raw frames exactly as the camera sent them.

export LC_ALL=C
VERSION=2
WIZARD=1
OUTBASE="$HOME/Desktop"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-wizard) WIZARD=0 ;;
    --out) shift; OUTBASE="${1:-$OUTBASE}" ;;
    -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script is for macOS. On Windows use camera-probe.ps1."
  exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$OUTBASE/thermal-probe-$STAMP"
RAW="$OUT/raw"
mkdir -p "$RAW" || { echo "Cannot create $OUT"; exit 1; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
ask()  { printf '%s' "$1"; read -r _ </dev/tty || true; }
lower(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- USB devices
# One line per device:    D|location|VID|PID|class|vendor|product|serial|usb
# One line per interface: I|location|number|class|subclass|protocol
AWK_USB=$(cat <<'EOF'
function hx(n, w) { return sprintf("0x%0" w "X", n + 0) }
function clean(s) { gsub(/\|/, "/", s); return s }
function flush() {
  if (kind == "D") {
    if (loc == "" || (loc in seen)) { skipdev = 1; curloc = "" }
    else {
      seen[loc] = 1; skipdev = 0; curloc = loc
      print "D|" loc "|" hx(vid, 4) "|" hx(pid, 4) "|" hx(dcls, 2) "|" clean(ven) "|" clean(prod) "|" clean(ser) "|" usb
    }
  } else if (kind == "I" && !skipdev && curloc != "") {
    print "I|" curloc "|" inum "|" hx(icls, 2) "|" hx(isub, 2) "|" hx(iproto, 2)
  }
  kind = ""
}
/\+-o / {
  flush()
  if (index($0, "<class " devcls ",")) {
    kind = "D"; vid = 0; pid = 0; dcls = 0; ven = ""; ser = ""; usb = ""; loc = ""
    prod = $0; sub(/.*\+-o /, "", prod); sub(/@.*/, "", prod); sub(/ +<class.*/, "", prod)
  } else if (index($0, "<class IOUSBHostInterface,") || index($0, "<class IOUSBInterface,")) {
    kind = "I"; inum = 0; icls = 0; isub = 0; iproto = 0
  }
  next
}
/"[^"]+" = / {
  if (kind == "") next
  line = $0; sub(/^[^"]*"/, "", line)
  k = line; sub(/".*$/, "", k)
  v = line; sub(/^[^"]*" = /, "", v); gsub(/^"|"$/, "", v)
  if (kind == "D") {
    if (k == "idVendor") vid = v
    else if (k == "idProduct") pid = v
    else if (k == "locationID") loc = sprintf("0x%08X", v + 0)
    else if (k == "bDeviceClass") dcls = v
    else if (k == "USB Vendor Name" || k == "kUSBVendorString") ven = v
    else if (k == "USB Product Name" || k == "kUSBProductString") prod = v
    else if (k == "USB Serial Number" || k == "kUSBSerialNumberString") ser = v
    else if (k == "bcdUSB") usb = sprintf("%x.%02x", int(v / 256), v % 256)
  } else {
    if (k == "bInterfaceNumber") inum = v
    else if (k == "bInterfaceClass") icls = v
    else if (k == "bInterfaceSubClass") isub = v
    else if (k == "bInterfaceProtocol") iproto = v
  }
}
END { flush() }
EOF
)

usb_list() {
  local cls
  for cls in IOUSBHostDevice IOUSBDevice; do
    if ioreg -r -c "$cls" -l -w0 2>/dev/null | grep -q "<class $cls,"; then
      ioreg -r -c "$cls" -l -w0 2>/dev/null | awk -v devcls="$cls" "$AWK_USB"
      return
    fi
  done
}

# ---------------------------------------------------------- cameras (macOS)
# Uses AVFoundation through JavaScript for Automation (built into macOS).
# One line per camera: C|index|name|uniqueID|modelID|manufacturer|transport
# One line per format: F|index|fourcc|width|height|minFps|maxFps|description
JXA_CAMS=$(cat <<'EOF'
ObjC.import('Foundation');
ObjC.import('AVFoundation');
ObjC.import('CoreMedia');
function s(x) {
  try { var r = ObjC.unwrap(x); if (r === undefined || r === null) return ''; return String(r).replace(/[|\r\n]+/g, ' '); }
  catch (e) { return ''; }
}
function cc(n) {
  if (typeof n !== 'number' || !n) return '';
  return String.fromCharCode((n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255);
}
var out = [];
try {
  var devs = $.AVCaptureDevice.devicesWithMediaType($('vide'));
  for (var i = 0; i < devs.count; i++) {
    var d = devs.objectAtIndex(i);
    var tt = ''; try { tt = cc(d.transportType); } catch (e) {}
    out.push(['C', i, s(d.localizedName), s(d.uniqueID), s(d.modelID), s(d.manufacturer), tt].join('|'));
    var fs = d.formats;
    for (var j = 0; j < fs.count; j++) {
      var f = fs.objectAtIndex(j), desc = s(f.description), sub = '', w = 0, h = 0, lo = '', hi = '';
      try {
        var fd = f.formatDescription;
        sub = cc($.CMFormatDescriptionGetMediaSubType(fd));
        var dm = $.CMVideoFormatDescriptionGetDimensions(fd);
        w = Number(dm.width) || 0; h = Number(dm.height) || 0;
      } catch (e) {}
      var m = desc.match(/'([^']{4})'\s+(\d+)\s*x\s*(\d+)/);
      if (m) { if (!sub) sub = m[1]; if (!w) w = Number(m[2]); if (!h) h = Number(m[3]); }
      try {
        var rr = f.videoSupportedFrameRateRanges;
        for (var k = 0; k < rr.count; k++) {
          var r = rr.objectAtIndex(k), a = Number(r.minFrameRate), b = Number(r.maxFrameRate);
          if (lo === '' || a < lo) lo = a;
          if (hi === '' || b > hi) hi = b;
        }
      } catch (e) {}
      if (hi === '') { var q = desc.match(/\{\s*([\d.]+)\s*-\s*([\d.]+)\s*fps/); if (q) { lo = Number(q[1]); hi = Number(q[2]); } }
      out.push(['F', i, sub, w, h, lo, hi, desc].join('|'));
    }
  }
} catch (e) { out.push('E|' + e); }
out.join('\n');
EOF
)

cams_list() { osascript -l JavaScript -e "$JXA_CAMS" 2>>"$RAW/avfoundation-errors.txt"; }

# ------------------------------------------------------------------- collect
say "Thermal camera probe for macOS (v$VERSION). Read-only; changes nothing."
say "Report folder: $OUT"

FFMPEG=$(command -v ffmpeg 2>/dev/null)
for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  [ -z "$FFMPEG" ] && [ -x "$p" ] && FFMPEG="$p"
done

if [ "$WIZARD" -eq 1 ]; then
  step "Step 1 of 2"
  ask "Close the camera maker's app, UNPLUG the thermal camera, then press Enter... "
  usb_list > "$RAW/usb-before.txt"
  cams_list > "$RAW/cameras-before.txt"
  step "Step 2 of 2"
  ask "Now PLUG the camera in, point it at the test object, wait about 5 seconds, then press Enter... "
  sleep 2
fi
usb_list > "$RAW/usb-after.txt"
cams_list > "$RAW/cameras-after.txt"
AFTER_USB="$RAW/usb-after.txt"
AFTER_CAMS="$RAW/cameras-after.txt"

step "Collecting system details"
ioreg -p IOUSB -l -w0 > "$RAW/ioreg-usb.txt" 2>&1
system_profiler SPUSBDataType > "$RAW/system_profiler-usb.txt" 2>&1
system_profiler SPUSBHostDataType > "$RAW/system_profiler-usbhost.txt" 2>&1
system_profiler SPCameraDataType > "$RAW/system_profiler-camera.txt" 2>&1

MACOS=$(sw_vers -productVersion 2>/dev/null)
MACBUILD=$(sw_vers -buildVersion 2>/dev/null)
ARCH=$(uname -m)
MODEL=$(sysctl -n hw.model 2>/dev/null)

# ------------------------------------------------------------- pick a target
has_iface() { grep -q "^I|$1|[^|]*|$2|" "$AFTER_USB"; }

if [ "$WIZARD" -eq 1 ]; then
  CANDIDATES=$(awk -F'|' 'NR==FNR { if ($1=="D") s[$2"|"$3"|"$4]=1; next }
                          $1=="D" && !(($2"|"$3"|"$4) in s) { print $2 }' "$RAW/usb-before.txt" "$AFTER_USB")
else
  CANDIDATES=$(awk -F'|' '$1=="D" && $3!="0x05AC" { print $2 }' "$AFTER_USB")
fi

TARGET=""
for loc in $CANDIDATES; do has_iface "$loc" 0x0E && { TARGET="$loc"; break; }; done
[ -z "$TARGET" ] && for loc in $CANDIDATES; do has_iface "$loc" 0xFF && { TARGET="$loc"; break; }; done
[ -z "$TARGET" ] && TARGET=$(awk -F'|' '$1=="D" && $3=="0x2BDF" { print $2; exit }' "$AFTER_USB")
[ -z "$TARGET" ] && [ "$WIZARD" -eq 1 ] && TARGET=$(printf '%s\n' $CANDIDATES | head -n 1)

T_VID=""; T_PID=""; T_CLS=""; T_VEN=""; T_PROD=""; T_SER=""; T_USB=""
if [ -n "$TARGET" ]; then
  IFS='|' read -r _ _ T_VID T_PID T_CLS T_VEN T_PROD T_SER T_USB <<< "$(grep "^D|$TARGET|" "$AFTER_USB" | head -n 1)"
fi

# ------------------------------------------- match the target to a camera
CAM_IDX=""; CAM_NAME=""; CAM_UID=""; CAM_MODEL=""
if [ -n "$T_VID" ]; then
  VDEC=$((T_VID)); PDEC=$((T_PID))
  VIDPID=$(printf '%04x%04x' "$VDEC" "$PDEC")
  while IFS='|' read -r kind idx name uid model manu tt; do
    [ "$kind" = "C" ] || continue
    case "$model" in *"VendorID_${VDEC}"*"ProductID_${PDEC}"*) CAM_IDX="$idx" ;; esac
    case "$(lower "$uid")" in *"$VIDPID"*) CAM_IDX="$idx" ;; esac
    if [ -n "$CAM_IDX" ]; then CAM_NAME="$name"; CAM_UID="$uid"; CAM_MODEL="$model"; break; fi
  done < "$AFTER_CAMS"
fi
if [ -z "$CAM_IDX" ] && [ "$WIZARD" -eq 1 ]; then
  # Fall back to whichever camera appeared after plugging in.
  NEWCAM=$(awk -F'|' 'NR==FNR { if ($1=="C") s[$4]=1; next } $1=="C" && !($4 in s) { print; exit }' \
           "$RAW/cameras-before.txt" "$AFTER_CAMS")
  if [ -n "$NEWCAM" ]; then
    IFS='|' read -r _ CAM_IDX CAM_NAME CAM_UID CAM_MODEL _ _ <<< "$NEWCAM"
  fi
fi

# Format summary: count|tall|rawGrey|bestFourcc|bestW|bestH|bestMaxFps
FMT="0|0|0||||"
if [ -n "$CAM_IDX" ]; then
  FMT=$(awk -F'|' -v i="$CAM_IDX" '
    $1=="F" && $2==i {
      f=$3; w=$4+0; h=$5+0; n++
      t = (w > 0 && w <= 640 && h * 10 >= w * 13)
      r = (f=="L016" || f=="L008" || f=="b16g" || f=="Y16 " || f=="L00h")
      tall += t; raw += r
      sc = t * 2 + r
      if (best == "" || sc > bs) { best = f "|" w "|" h "|" $7; bs = sc }
    }
    END { print n+0 "|" tall+0 "|" raw+0 "|" best }' "$AFTER_CAMS")
fi
IFS='|' read -r F_COUNT F_TALL F_RAW B_CC B_W B_H B_FPS <<< "$FMT"

# ------------------------------------------------------ optional frame grab
FF_NOTE="ffmpeg not installed, so no raw frames were saved"
FF_STREAM=""
if [ -n "$FFMPEG" ] && { [ -n "$CAM_IDX" ] || [ -n "$TARGET" ]; }; then
  step "Grabbing frames with ffmpeg"
  "$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" > "$RAW/ffmpeg-devices.txt" 2>&1
  ff_find() {
    awk -v name="$1" '
      /video devices/ { v=1; next } /audio devices/ { v=0 }
      v && match($0, /\[[0-9]+\] /) { n=substr($0, RSTART+1, RLENGTH-3); if (substr($0, RSTART+RLENGTH) == name) { print n; exit } }'       "$RAW/ffmpeg-devices.txt"
  }
  FF_IDX=""
  for nm in "$CAM_NAME" "$T_PROD" "UVC Camera"; do
    [ -n "$nm" ] && [ -z "$FF_IDX" ] && FF_IDX=$(ff_find "$nm")
  done
  [ -z "$FF_IDX" ] && FF_IDX="$CAM_IDX"
fi
if [ -n "$FFMPEG" ] && [ -n "$FF_IDX" ]; then
  ARGS=(-hide_banner -f avfoundation)
  # ffmpeg defaults to 29.97 fps, which this camera (max 25) rejects.
  if [ -n "$B_FPS" ]; then ARGS+=(-framerate "$(printf '%.2f' "$B_FPS")"); else ARGS+=(-framerate 25); fi
  if [ "${B_W:-0}" -gt 0 ] 2>/dev/null; then ARGS+=(-video_size "${B_W}x${B_H}"); fi
  case "$B_CC" in
    yuvs) ARGS+=(-pixel_format yuyv422) ;;
    2vuy) ARGS+=(-pixel_format uyvy422) ;;
    420v|420f) ARGS+=(-pixel_format nv12) ;;
    L008) ARGS+=(-pixel_format gray) ;;
  esac
  ARGS+=(-i "${FF_IDX}:none" -vf "select=gte(n\,10)")

  say "macOS may ask to let Terminal use the camera. Click OK if it does."
  "$FFMPEG" "${ARGS[@]}" -frames:v 1 -y "$OUT/frame.png" > "$RAW/ffmpeg-png.txt" 2>&1
  if [ ! -s "$OUT/frame.png" ]; then
    say "The first try did not get a picture (often the camera permission pop-up)."
    ask "If macOS asked about the camera, click OK. Then press Enter to try again... "
    "$FFMPEG" "${ARGS[@]}" -frames:v 1 -y "$OUT/frame.png" > "$RAW/ffmpeg-png.txt" 2>&1
  fi
  # Ten consecutive frames, bytes exactly as the camera sent them.
  "$FFMPEG" "${ARGS[@]}" -frames:v 10 -f rawvideo -y "$OUT/frames-native.raw" > "$RAW/ffmpeg-raw.txt" 2>&1
  FF_STREAM=$(grep -m1 "Stream #0:0" "$RAW/ffmpeg-raw.txt" | sed 's/^ *//')
  if [ -s "$OUT/frame.png" ]; then FF_NOTE="frame.png saved"; else FF_NOTE="ffmpeg could not grab a picture (see raw/ffmpeg-png.txt)"; fi
  if [ -s "$OUT/frames-native.raw" ]; then
    FF_NOTE="$FF_NOTE; frames-native.raw saved ($(wc -c < "$OUT/frames-native.raw" | tr -d ' ') bytes, 10 frames)"
  else
    FF_NOTE="$FF_NOTE; raw frames NOT saved (see raw/ffmpeg-raw.txt)"
  fi
elif [ -n "$FFMPEG" ]; then
  FF_NOTE="ffmpeg found, but no camera to grab from"
fi

# ------------------------------------------------------------------- verdict
if [ -z "$TARGET" ]; then
  V_CODE="INCONCLUSIVE"
  V_TITLE="Camera not identified"
  V_DETAIL="No new USB device appeared. Check the cable and port, then run again (or use --no-wizard)."
elif has_iface "$TARGET" 0x0E; then
  if [ -n "$CAM_IDX" ] && { [ "${F_TALL:-0}" -gt 0 ] || [ "${F_RAW:-0}" -gt 0 ]; }; then
    V_CODE="DIRECT_WITH_TEMPERATURE"
    V_TITLE="Standard USB camera that appears to send temperature data"
    V_DETAIL="macOS offers a raw greyscale or double-height format. A native Android app can likely read it without an SDK."
  elif [ -n "$CAM_IDX" ]; then
    V_CODE="IMAGE_ONLY"
    V_TITLE="Standard USB camera, picture only"
    V_DETAIL="It opens like a webcam, but no format carries raw data. Live view is possible; temperatures likely need the maker's SDK."
  else
    V_CODE="UVC_NOT_EXPOSED"
    V_TITLE="Standard USB camera, but macOS does not list it as a camera"
    V_DETAIL="USB says it is a video device, yet macOS shows no camera for it. Its video formats may be non-standard. Send the zip for a closer look."
  fi
elif has_iface "$TARGET" 0xFF; then
  V_CODE="PROPRIETARY"
  V_TITLE="Vendor-specific USB device"
  V_DETAIL="It does not use the standard USB video class. Reading it needs the maker's SDK."
else
  V_CODE="INCONCLUSIVE"
  V_TITLE="A USB device appeared, but it is not a video device"
  V_DETAIL="The new device has no video interface. Make sure it is the camera, then run again."
fi

# -------------------------------------------------------------------- report
IFACES=$( [ -n "$TARGET" ] && grep "^I|$TARGET|" "$AFTER_USB")
FORMATS=$( [ -n "$CAM_IDX" ] && awk -F'|' -v i="$CAM_IDX" '$1=="F" && $2==i' "$AFTER_CAMS")
class_name() {
  case "$1" in
    0x0E) echo "Video (UVC, standard USB camera)" ;; 0xFF) echo "Vendor-specific" ;;
    0x01) echo "Audio" ;; 0x03) echo "HID" ;; 0x08) echo "Mass storage" ;; 0xEF) echo "Miscellaneous" ;;
    0x00) echo "Per-interface" ;; *) echo "Other" ;;
  esac
}

{
  say "Thermal camera probe (macOS) v$VERSION   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "macOS $MACOS ($MACBUILD), $ARCH, $MODEL"
  say "Wizard: $([ "$WIZARD" -eq 1 ] && echo yes || echo no)"
  say ""
  say "VERDICT: $V_CODE"
  say "  $V_TITLE"
  say "  $V_DETAIL"
  say ""
  say "USB device"
  if [ -n "$TARGET" ]; then
    say "  $T_VEN $T_PROD  VID $T_VID  PID $T_PID  class $T_CLS  USB $T_USB  serial $T_SER  location $TARGET"
    printf '%s\n' "$IFACES" | while IFS='|' read -r _ _ n c s p; do
      [ -n "$c" ] && say "  interface $n: class $c/$s/$p  $(class_name "$c")"
    done
  else
    say "  (not identified)"
  fi
  say ""
  say "macOS camera"
  if [ -n "$CAM_IDX" ]; then
    say "  $CAM_NAME  ($CAM_MODEL)  id $CAM_UID"
    say "  $F_COUNT format(s), $F_TALL tall, $F_RAW raw greyscale"
    printf '%s\n' "$FORMATS" | while IFS='|' read -r _ _ f w h lo hi _; do
      [ -n "$w" ] && say "  '$f' ${w}x${h}  ${lo}-${hi} fps"
    done
  else
    say "  (no matching camera)"
  fi
  say ""
  say "All cameras macOS lists:"
  awk -F'|' '$1=="C" { print "  [" $2 "] " $3 "  (" $5 ")" } $1=="E" { print "  error: " $2 }' "$AFTER_CAMS"
  say ""
  say "Frame grab: $FF_NOTE"
  [ -n "$FF_STREAM" ] && say "  $FF_STREAM"
} > "$OUT/report.txt"

js() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"; }
jn() { case "$1" in ''|*[!0-9.]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

{
  printf '{\n  "tool": "thermal-camera-probe/macos",\n  "version": %s,\n' "$VERSION"
  printf '  "createdAt": %s,\n' "$(js "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf '  "environment": {"macos": %s, "build": %s, "arch": %s, "model": %s, "wizard": %s, "ffmpeg": %s},\n' \
    "$(js "$MACOS")" "$(js "$MACBUILD")" "$(js "$ARCH")" "$(js "$MODEL")" \
    "$([ "$WIZARD" -eq 1 ] && echo true || echo false)" "$([ -n "$FFMPEG" ] && echo true || echo false)"
  if [ -n "$TARGET" ]; then
    printf '  "usb": {"location": %s, "vendorId": %s, "productId": %s, "deviceClass": %s, "manufacturer": %s, "product": %s, "serial": %s, "usbVersion": %s, "interfaces": [' \
      "$(js "$TARGET")" "$(js "$T_VID")" "$(js "$T_PID")" "$(js "$T_CLS")" "$(js "$T_VEN")" "$(js "$T_PROD")" "$(js "$T_SER")" "$(js "$T_USB")"
    sep=""
    while IFS='|' read -r _ _ n c s p; do
      [ -n "$c" ] || continue
      printf '%s{"number": %s, "class": %s, "subclass": %s, "protocol": %s, "className": %s}' \
        "$sep" "$(jn "$n")" "$(js "$c")" "$(js "$s")" "$(js "$p")" "$(js "$(class_name "$c")")"
      sep=", "
    done <<< "$IFACES"
    printf ']},\n'
  else
    printf '  "usb": null,\n'
  fi
  if [ -n "$CAM_IDX" ]; then
    printf '  "camera": {"name": %s, "uniqueId": %s, "modelId": %s, "formats": [' "$(js "$CAM_NAME")" "$(js "$CAM_UID")" "$(js "$CAM_MODEL")"
    sep=""
    while IFS='|' read -r _ _ f w h lo hi d; do
      [ -n "$w" ] || continue
      printf '%s\n    {"fourcc": %s, "width": %s, "height": %s, "minFps": %s, "maxFps": %s, "description": %s}' \
        "$sep" "$(js "$f")" "$(jn "$w")" "$(jn "$h")" "$(jn "$lo")" "$(jn "$hi")" "$(js "$d")"
      sep=","
    done <<< "$FORMATS"
    printf ']},\n'
  else
    printf '  "camera": null,\n'
  fi
  printf '  "allCameras": ['
  sep=""
  while IFS='|' read -r kind idx name uid model manu tt; do
    [ "$kind" = "C" ] || continue
    printf '%s{"index": %s, "name": %s, "modelId": %s, "manufacturer": %s, "transport": %s}' \
      "$sep" "$(jn "$idx")" "$(js "$name")" "$(js "$model")" "$(js "$manu")" "$(js "$tt")"
    sep=", "
  done < "$AFTER_CAMS"
  printf '],\n'
  printf '  "frameGrab": {"note": %s, "stream": %s},\n' "$(js "$FF_NOTE")" "$(js "$FF_STREAM")"
  printf '  "verdict": {"code": %s, "title": %s, "detail": %s}\n}\n' "$(js "$V_CODE")" "$(js "$V_TITLE")" "$(js "$V_DETAIL")"
} > "$OUT/report.json"

ZIP="$OUT.zip"
ditto -c -k --keepParent "$OUT" "$ZIP" 2>/dev/null

step "Result"
cat "$OUT/report.txt"
say ""
if [ -z "$FFMPEG" ]; then
  say "NOTE: ffmpeg is not installed, so the camera's raw frames were NOT saved."
  say "      Install it (brew install ffmpeg) and run this again."
fi
if [ -f "$ZIP" ]; then say "DONE. Send this file: $ZIP"; else say "DONE. Send the folder: $OUT"; fi
