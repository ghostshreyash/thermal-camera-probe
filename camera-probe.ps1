<#
.SYNOPSIS
  Thermal Camera Probe (Windows). Finds out whether a USB thermal camera can be
  read directly, without the maker's own app or SDK.

.DESCRIPTION
  1. Asks you to unplug the camera, then plug it back in, so it can tell exactly
     which USB device is the camera (skip with -NoWizard).
  2. Reports its USB identity: vendor/product ID, USB class, Windows driver.
  3. Lists every video format the camera offers (Windows camera API).
  4. If ffmpeg is installed, saves ten raw frames exactly as the camera sent
     them (its default mode, then 96x322 if offered) and one PNG. Every
     capture stops itself after 15 seconds instead of hanging.
  5. Gives a verdict and writes everything to a folder on the Desktop, zipped.

  Read-only: nothing on the camera or the PC is changed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera-probe.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\camera-probe.ps1 -NoWizard
#>
[CmdletBinding()]
param(
  # List every USB/camera device instead of the unplug/replug comparison
  [switch]$NoWizard,
  # Where the report folder goes
  [string]$OutDir = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

if ($PSVersionTable.PSEdition -eq 'Core') {
  Write-Host "Please run this in Windows PowerShell (powershell.exe), not PowerShell 7:" -ForegroundColor Yellow
  Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit 1
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutDir "thermal-probe-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$usbClasses = @{
  '00'='Defined per interface'; '01'='Audio'; '02'='Communications'; '03'='HID'; '06'='Still image'
  '07'='Printer'; '08'='Mass storage'; '09'='Hub'; '0A'='CDC data'; '0E'='Video (UVC - standard USB camera)'
  '10'='Audio/Video'; 'DC'='Diagnostic'; 'E0'='Wireless'; 'EF'='Miscellaneous'; 'FE'='Application specific'
  'FF'='Vendor specific (proprietary)'
}

function Write-Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }

function Get-UsbSnapshot {
  Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^USB' -or $_.Class -in 'Camera','Image','USBDevice' }
}

function Get-Prop($instanceId, $key) {
  try { (Get-PnpDeviceProperty -InstanceId $instanceId -KeyName $key -ErrorAction Stop).Data } catch { $null }
}

function Describe-Device($dev) {
  $id   = $dev.InstanceId
  $vid  = if ($id -match 'VID_([0-9A-F]{4})') { $Matches[1] } else { $null }
  $usbPid = if ($id -match 'PID_([0-9A-F]{4})') { $Matches[1] } else { $null }
  $mi   = if ($id -match 'MI_([0-9A-F]{2})')  { $Matches[1] } else { $null }
  $compat = @(Get-Prop $id 'DEVPKEY_Device_CompatibleIds')
  $classes = @($compat | ForEach-Object { if ($_ -match 'Class_([0-9A-F]{2})') { $Matches[1].ToUpper() } } | Select-Object -Unique)
  [pscustomobject]@{
    Name          = $dev.FriendlyName
    WindowsClass  = $dev.Class
    Status        = $dev.Status
    VendorId      = $vid
    ProductId     = $usbPid
    Interface     = $mi
    UsbClasses    = ($classes | ForEach-Object { "0x$_ $($usbClasses[$_])" }) -join '; '
    Driver        = Get-Prop $id 'DEVPKEY_Device_Service'
    DriverVendor  = Get-Prop $id 'DEVPKEY_Device_DriverProvider'
    Manufacturer  = Get-Prop $id 'DEVPKEY_Device_Manufacturer'
    BusReportedName = Get-Prop $id 'DEVPKEY_Device_BusReportedDeviceDesc'
    InstanceId    = $id
    CompatibleIds = $compat -join '; '
    _classes      = $classes
  }
}

# ---------------------------------------------------------------- 1. find it
Write-Step "1. Finding the camera"
if ($NoWizard) {
  $devices = @(Get-UsbSnapshot)
  Write-Host "Listing all USB and camera devices ($($devices.Count))."
} else {
  Write-Host "Close the camera maker's app if it is open."
  Read-Host  "UNPLUG the thermal camera, then press Enter" | Out-Null
  Start-Sleep -Seconds 2
  $before = @(Get-UsbSnapshot | ForEach-Object InstanceId)
  Read-Host  "PLUG the thermal camera back in, wait 5 seconds, then press Enter" | Out-Null
  Start-Sleep -Seconds 3
  $devices = @(Get-UsbSnapshot | Where-Object { $before -notcontains $_.InstanceId })
  if ($devices.Count -eq 0) {
    Write-Host "No new device appeared. Is the camera plugged in, and does Windows make a sound when it connects?" -ForegroundColor Yellow
    Write-Host "Falling back to listing every USB and camera device."
    $devices = @(Get-UsbSnapshot)
  } else {
    Write-Host "$($devices.Count) new device entr$(if ($devices.Count -eq 1) {'y'} else {'ies'}) appeared." -ForegroundColor Green
  }
}
$described = @($devices | ForEach-Object { Describe-Device $_ })
$described | Select-Object Name, WindowsClass, VendorId, ProductId, Interface, UsbClasses, Driver |
  Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$vidPids = @($described | Where-Object VendorId | ForEach-Object { "VID_$($_.VendorId)&PID_$($_.ProductId)" } | Select-Object -Unique)

# ---------------------------------------------------------------- 2. formats
Write-Step "2. Video formats offered (Windows camera API)"
$formats = @()
$cameraNames = @()
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
  function Await($op, [Type]$type) { $t = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); $null = $t.Wait(-1); $t.Result }
  function AwaitAction($op) { $t = $asTaskAction.Invoke($null, @($op)); $null = $t.Wait(-1) }

  $null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
  $null = [Windows.Media.Capture.Frames.MediaFrameSourceGroup, Windows.Media.Capture, ContentType = WindowsRuntime]
  $groups = Await ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) `
    ([System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]])

  $groups = @($groups | ForEach-Object { $_ })
  Write-Host "Windows sees $($groups.Count) camera(s)."
  foreach ($g in $groups) {
    $isTarget = ($vidPids.Count -eq 0) -or [bool]($vidPids | Where-Object { $g.Id -match [regex]::Escape($_) })
    Write-Host ("Camera: {0}{1}" -f $g.DisplayName, $(if ($isTarget -and $vidPids.Count) { '   <-- the plugged-in device' } else { '' }))
    $cameraNames += [pscustomobject]@{ Name = $g.DisplayName; Id = $g.Id; IsTarget = $isTarget }
    if (-not $isTarget) { continue }

    $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
    $settings.SourceGroup = $g
    $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly
    $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    $mc = New-Object Windows.Media.Capture.MediaCapture
    try {
      AwaitAction ($mc.InitializeAsync($settings))
      foreach ($src in $mc.FrameSources.Values) {
        foreach ($f in $src.SupportedFormats) {
          $fps = if ($f.FrameRate.Denominator) { [math]::Round($f.FrameRate.Numerator / $f.FrameRate.Denominator, 2) } else { $null }
          $formats += [pscustomobject]@{
            Camera  = $g.DisplayName
            Source  = "$($src.Info.SourceKind)"
            Subtype = $f.Subtype
            Width   = $f.VideoFormat.Width
            Height  = $f.VideoFormat.Height
            Fps     = $fps
          }
        }
      }
    } catch {
      Write-Host "  Could not open it: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally { $mc.Dispose() }
  }
} catch {
  Write-Host "Windows camera API unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
}
$formats = @($formats | Sort-Object Camera, Subtype, Width, Height, Fps -Unique)
if ($formats.Count) { $formats | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
else { Write-Host "No video formats found for the camera (it may not be a standard USB camera)." -ForegroundColor Yellow }

# ---------------------------------------------------------------- 3. ffmpeg frames
Write-Step "3. Raw frame capture (needs ffmpeg)"
# ffmpeg installed with winget in this same window is not on PATH until the
# window is reopened; read PATH again so it is found either way
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$frameFiles = @()
$captures = @()
$target = $cameraNames | Where-Object IsTarget | Select-Object -First 1

<#
  Run ffmpeg, but never let it hang. A camera can accept a mode and then send
  nothing: on Windows the MiniE's 96x322 mode never starts, and ffmpeg then
  waits for ever. Stopping it with Ctrl+C leaves the camera wedged until it is
  replugged, so the script stops it itself after a time limit.
#>
function Invoke-Ffmpeg([string[]]$ArgList, [string]$LogName, [int]$Seconds = 15) {
  $log = Join-Path $outDir $LogName
  $quoted = $ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
  $p = Start-Process -FilePath $ffmpeg.Source -ArgumentList ($quoted -join ' ') -NoNewWindow -PassThru `
    -RedirectStandardError $log -RedirectStandardOutput (Join-Path $outDir 'ffmpeg-stdout.txt')
  if (-not $p.WaitForExit($Seconds * 1000)) {
    try { $p.Kill() } catch { }
    return 'timeout'
  }
  return 'done'
}

<# Grab ten frames exactly as the camera sends them; $Size empty = the camera's default mode #>
function Get-RawFrames([string]$Name, [string]$Size, [string]$File) {
  $ffArgs = @('-hide_banner', '-loglevel', 'info', '-y', '-f', 'dshow', '-rtbufsize', '64M')
  if ($Size) { $ffArgs += @('-video_size', $Size, '-pixel_format', 'yuyv422') }
  $ffArgs += @('-i', "video=$Name", '-frames:v', '10', '-c:v', 'copy', '-f', 'rawvideo', (Join-Path $outDir $File))
  $logName = ($File -replace '\.raw$', '') + '-ffmpeg.txt'
  $outcome = Invoke-Ffmpeg $ffArgs $logName
  $path = Join-Path $outDir $File
  $bytes = if (Test-Path $path) { (Get-Item $path).Length } else { 0 }
  # The frame size the camera actually streamed, from ffmpeg's own log
  $w = 0; $h = 0
  $logText = Get-Content (Join-Path $outDir $logName) -Raw -ErrorAction SilentlyContinue
  if ($logText -and $logText -match 'Video: .*?, (\d+)x(\d+)') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
  $frameBytes = $w * $h * 2
  $frames = if ($frameBytes) { [math]::Floor($bytes / $frameBytes) } else { 0 }
  $whole = $frameBytes -and $bytes -gt 0 -and ($bytes % $frameBytes) -eq 0
  if ($bytes -eq 0 -and (Test-Path $path)) { Remove-Item $path }
  [pscustomobject]@{ File = $File; Requested = $(if ($Size) { $Size } else { 'default' }); Width = $w; Height = $h
    Bytes = $bytes; Frames = $frames; WholeFrames = [bool]$whole; Outcome = $outcome }
}

if (-not $ffmpeg) {
  Write-Host "ffmpeg not installed - skipping. (Install it with 'winget install Gyan.FFmpeg', then run again.)" -ForegroundColor Yellow
} elseif (-not $target) {
  Write-Host "No camera to capture from - skipping."
} else {
  $name = $target.Name
  Write-Host "Capturing from '$name'. Keep the camera still, pointed at the object..."
  $listing = Invoke-Ffmpeg @('-hide_banner', '-list_options', 'true', '-f', 'dshow', '-i', "video=$name") 'ffmpeg-formats.txt'

  # 1. The camera's own default mode first: on Windows this is the one that streams (96x176 on the MiniE)
  $captures += Get-RawFrames $name '' 'frames-native.raw'
  # 2. A picture, for a person to see what was in front of the camera
  $png = Join-Path $outDir 'frame.png'
  $null = Invoke-Ffmpeg @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'dshow', '-rtbufsize', '64M', '-i', "video=$name", '-frames:v', '1', $png) 'ffmpeg-png.txt'
  # 3. The full 96x322 mode last, because it may never start and leave the camera needing a replug
  if (Select-String -InputObject ((Get-Content (Join-Path $outDir 'ffmpeg-formats.txt') -Raw -ErrorAction SilentlyContinue) + '') -Pattern 's=96x322' -Quiet) {
    $captures += Get-RawFrames $name '96x322' 'frames-96x322.raw'
  }

  foreach ($c in $captures) {
    if ($c.Bytes -gt 0) { $frameFiles += $c.File }
    $line = if ($c.Bytes -gt 0) {
      "$($c.File) saved ($($c.Bytes) bytes, $($c.Frames) frames of $($c.Width)x$($c.Height))" + $(if (-not $c.WholeFrames) { ' - WARNING: not whole frames' } else { '' })
    } elseif ($c.Outcome -eq 'timeout') {
      "$($c.Requested) mode: the camera sent nothing in 15 seconds (normal for 96x322 on Windows)"
    } else { "$($c.Requested) mode: capture failed (see $($c.File -replace '\.raw$', '')-ffmpeg.txt)" }
    Write-Host ("Frame grab: " + $line) -ForegroundColor $(if ($c.Bytes -gt 0) { 'Green' } else { 'Yellow' })
  }
  if (Test-Path $png) { $frameFiles += 'frame.png' }
  if (-not ($captures | Where-Object Bytes)) {
    Write-Host "No raw frames were saved. Unplug the camera, plug it back in, and run the script again." -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- 4. verdict
Write-Step "4. Result"
$allClasses = @($described | ForEach-Object { $_._classes })
$isUvc     = ($allClasses -contains '0E') -or [bool]($described | Where-Object { $_.Driver -eq 'usbvideo' })
$isVendor  = $allClasses -contains 'FF'
$rawSubtypes = @('Y16','L16','D16','Y8','L8','GRAY')
$rawFormat = $formats | Where-Object { $rawSubtypes -contains ($_.Subtype -replace '^MFVideoFormat_','').ToUpper() } | Select-Object -First 1
$tallFormat = $formats | Where-Object { $_.Width -le 640 -and $_.Height -ge [math]::Round($_.Width * 1.3) } | Select-Object -First 1

if ($isUvc -and ($rawFormat -or $tallFormat)) {
  $verdict = @{ Code = 'DIRECT_WITH_TEMPERATURE'; Colour = 'Green'
    Title = 'Direct integration looks possible - standard USB camera that appears to send temperature data'
    Detail = "It is a standard USB video device and offers " + $(if ($rawFormat) { "a raw $($rawFormat.Subtype) $($rawFormat.Width)x$($rawFormat.Height) format" } else { "a double-height $($tallFormat.Width)x$($tallFormat.Height) frame (picture + data)" }) + ". Accuracy must still be checked against the maker's app." }
} elseif ($isUvc) {
  $verdict = @{ Code = 'IMAGE_ONLY'; Colour = 'Yellow'
    Title = 'Standard USB camera, but only a picture'
    Detail = 'It opens like a webcam, but no raw or double-height format was found. Live thermal pictures are possible; temperatures would need the maker''s SDK.' }
} elseif ($isVendor) {
  $verdict = @{ Code = 'PROPRIETARY'; Colour = 'Red'
    Title = 'Proprietary device - needs the maker''s SDK'
    Detail = 'The camera uses a vendor-specific USB interface, not the standard camera class. Direct integration needs the maker''s SDK.' }
} else {
  $verdict = @{ Code = 'INCONCLUSIVE'; Colour = 'Yellow'
    Title = 'Inconclusive'
    Detail = 'The camera could not be identified. Check it is plugged in and try again, or run with -NoWizard and send the report.' }
}
Write-Host $verdict.Title -ForegroundColor $verdict.Colour
Write-Host $verdict.Detail

# ---------------------------------------------------------------- 5. save
$report = [ordered]@{
  tool      = 'thermal-camera-probe/windows'
  version   = 2
  createdAt = (Get-Date).ToString('o')
  computer  = @{ os = (Get-CimInstance Win32_OperatingSystem).Caption; build = [Environment]::OSVersion.Version.ToString(); powershell = $PSVersionTable.PSVersion.ToString() }
  mode      = $(if ($NoWizard) { 'list-all' } else { 'unplug-replug' })
  devices   = @($described | Select-Object * -ExcludeProperty _classes)
  cameras   = $cameraNames
  formats   = $formats
  ffmpeg    = @{ installed = [bool]$ffmpeg; frames = $frameFiles; captures = $captures }
  verdict   = @{ code = $verdict.Code; title = $verdict.Title; detail = $verdict.Detail }
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir 'report.json') -Encoding UTF8

$text = @(
  "Thermal Camera Probe - $(Get-Date)"
  ""
  "RESULT: $($verdict.Title)"
  $verdict.Detail
  ""
  "DEVICES"
  ($described | Select-Object Name, WindowsClass, VendorId, ProductId, Interface, UsbClasses, Driver, DriverVendor, Manufacturer, InstanceId | Format-List | Out-String)
  "VIDEO FORMATS"
  $(if ($formats.Count) { $formats | Format-Table -AutoSize | Out-String -Width 200 } else { '(none)' })
)
Set-Content -Path (Join-Path $outDir 'report.txt') -Value $text -Encoding UTF8

$zip = "$outDir.zip"
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -Force
Write-Step "Done"
Write-Host "Send this file to the EVITA team:" -ForegroundColor Green
Write-Host "  $zip"
