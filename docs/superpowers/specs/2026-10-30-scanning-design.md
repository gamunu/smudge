# Scanning through Image Capture

Status: design, not built. Date: 2026-10-30.

## Why

HP sold the DeskJet Ink Advantage 2336 (DeskJet 2300 series) with a
flatbed scanner and a USB port, and ships nothing that lets a Mac use
the scanner. HP Smart only looks for network printers. HPLIP has a
working scanner backend for this family, but it is SANE code for Linux.

Smudge already prints on this printer and reads its ink levels over
USB. Scanning is the last piece of hardware a Mac owner still cannot
use.

The user wants the scanner to behave like any Mac-supported scanner.
It should show up in Image Capture, in Preview's "Import from Scanner",
and in any app built on ImageCaptureCore, with the adjustments those
apps already offer. We do not write our own scan window.

## What we know (measured, not guessed)

**macOS accepts a scanner that only exists on this Mac.** A throwaway
spike on macOS 27.2 served eSCL (AirScan) over HTTP on `127.0.0.1` and
announced it with Bonjour on the local-only interface
(`dns-sd -lo -R <name> _uscan._tcp local <port> ...`). The system's
`AirScanScanner.app` found it right away. Image Capture listed it under
SHARED, sent a real scan job and saved the file. The full exchange:

```
GET  /eSCL/ScannerCapabilities
GET  /eSCL/ScannerStatus            (polled every ~3 s while selected)
POST /eSCL/ScanJobs                 -> 201, Location: /eSCL/ScanJobs/N
GET  /eSCL/ScanJobs/N/NextDocument  -> 200 image/jpeg
GET  /eSCL/ScanJobs/N/NextDocument  -> 404 (no more pages)
DELETE /eSCL/ScanJobs/N
```

The ScanSettings Image Capture sent for a default scan:
Intent `TextAndGraphic`, region 2480 x 3508 in 1/300 inch (A4) at 0,0,
`image/jpeg`, InputSource `Platen`, ColorMode `RGB24`, 300 x 300 dpi,
eSCL version 2.0. The Host header arrives as `localhost.:<port>`.

Two failures during the spike, both now requirements:

1. With a minimal ScannerCapabilities and ScannerStatus, Image Capture
   showed "Scanning document" forever and never POSTed a job. It
   started posting after the replies gained `<scan:Jobs>` in the
   status, `MaxPhysicalWidth`/`MaxPhysicalHeight`, `ColorSpaces` (sRGB),
   a `BlackAndWhite1` color mode, and `BrightnessSupport` /
   `ContrastSupport`. Which of these was the one that mattered was not
   isolated. Send all of them.
2. With an empty `<scan:Jobs/>` list, Image Capture POSTed the job and
   DELETEd it at once without fetching a page. It worked once
   ScannerStatus listed every job as `<scan:JobInfo>` with `JobUri`,
   `JobUuid`, `Age`, `ImagesCompleted`, `ImagesToTransfer`,
   `JobState` (`Processing`, then `Completed`) and a `JobStateReason`.

Bonjour registration does not need an Apple binary. A plain
ad-hoc-signed Swift executable called `DNSServiceRegister` with
`kDNSServiceInterfaceIndexLocalOnly`. It registered with no Local
Network prompt, and `dns-sd -lo -B` listed it. That test ran from a
terminal session, not under launchd, so the first build step repeats it
as a LaunchAgent. A Local Network prompt there would mean moving the
agent into an app bundle (see "Left to the builder").

AirScanScanner logs an error-level line after status replies it
dislikes, but the text is redacted as `<private>`. Plan to debug the
bridge from its own request log, not the system log. (In this shell,
`log` is a function; the system tool is `/usr/bin/log`.)

**The printer has an LEDM scanner and no eSCL.** Read over USB from the
2336 (USB product 0x3654, LEDM on interface 2, vendor class
255/4/1). `/DevMgmt/DiscoveryTree.xml` lists
`/Scan/ScanJobManifest.xml`. `/eSCL/ScannerCapabilities` returns 404.
The manifest exposes `/Scan/ScanCaps` (GET), `/Scan/Status` (GET),
`/Scan/Jobs` (POST), `/Scan/BufferInfo` (PUT) and `/Scan/SPF`.

`/Scan/ScanCaps.xml` (full copy in
`2026-10-30-scanning-scancaps-deskjet-2300.xml` next to this file):

- Model "DeskJet Ink Advantage 2300 All-in-One Printer series".
- Platen only. No ADF, no duplex.
- Area 8..2550 wide, 8..3508 high, in 1/300 inch (Letter width, A4
  length). Risky margins 34/34/42/45.
- Resolutions 75, 100, 200, 300, 600, 1200 (X = Y), every color type
  at every resolution. Max optical 1200.
- `Color8` and `Gray8`: Raw or Jpeg. `K1` (1-bit): Raw only.
- Transforms: ToneMap and Sharpening on all three, BwThreshold on K1.
- `/Scan/Status.xml` idle reply: `<ScannerState>Idle</ScannerState>`.

**Scanning has its own USB interface.** The 2336 exposes interface 0
as vendor class 255/204/0 (ff/cc/0), interface 1 as the printer class
(7/1/2, used by the CUPS backend), and interfaces 2 and 3 as LEDM
255/4/1 (Smudge's ink and maintenance). HPLIP opens scanning on the
`HP-LEDM-SCAN` channel, which `io/hpmud/musb.c` maps to ff/cc/0. A
read-only probe over interface 0 got HTTP 200 for `/Scan/Status` and
`/Scan/ScanCaps`, the same documents as over interface 2. The bridge
therefore never needs the interface the app uses.

**The LEDM job protocol** (HPLIP 3.22.10 `scan/sane/bb_ledm.c`; 3.25.2
is expected to match):

- `POST /Scan/Jobs` with a `ScanSettings` document in namespace
  `http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19`, fields
  in this order: XResolution, YResolution, XStart, Width, YStart,
  Height, Format (`Jpeg` or `Raw`), CompressionQFactor 0, ColorSpace
  (`Color` or `Gray`), BitDepth 8, InputSource, InputSourceType
  (`Platen`), GrayRendering NTSC, ToneMap (Gamma 0, Brightness,
  Contrast, Highlite 0, Shadow 0), ContentType Photo. Geometry is in
  1/300 inch, the same unit eSCL uses, so no conversion is needed.
- The reply's `Location` header is the job URL (it contains
  `JobList/<n>`). The client GETs it every 0.5 s until the page state
  is `ReadyToUpload`, then GETs the page's `<BinaryURL>`. The image
  arrives chunked. `CanceledByDevice` / `CanceledByClient` page states
  and the `Completed` job state end the job. No `PreScanPage` in the
  job means no document.
- Cancel is `PUT <job URL>` with a `j:Job` document whose body is
  `<j:JobState>Canceled</j:JobState>`.
- HPLIP sends no fields for Sharpening or BwThreshold. HPLIP gets K1
  (black and white) by asking for Gray and thresholding on the host.

### Measured on the 2336 (probe)

`smudge-scand --probe`, one scan per run, with the printer's alignment
page on the glass:

- **Job flow.** POST returns `201` with `Location: /Jobs/JobList/<n>`.
  The first job replies show `PreScanPage` with `PageState
  PreparingScan`. Then `ReadyToUpload` with
  `BinaryURL /Scan/Jobs/<n>/Pages/1`, and the reply also carries
  `ImageWidth`, `ImageHeight` and `BytesPerLine`. After the download the
  job is `Completed`, with `PostScanPage`, `UploadCompleted` and
  `TotalLines`. Ending the poll early without a cancel leaves the
  printer scanning the whole page.
- **Raw works**, although HPLIP never asks for it. The data is headerless
  rows, `floor(Width*res/300)` pixels wide and `floor(Height*res/300)`
  rows. Gray is 1 byte per pixel, and color is interleaved RGB at 3
  bytes. There is no row padding. At 75 dpi, full glass: 637 x 877,
  558649 bytes gray and 1675947 color.
- **ToneMap is applied by the device.** At 75 dpi gray, the mean and
  spread against the default (1000/1000, mean 242.5, sd 41.7):
  Brightness 0 gives 177.0, Brightness 2000 gives 248.4, Contrast 0
  gives sd 20.7, and Contrast 2000 gives sd 49.9. Neutral is 1000, the
  range is 0 to 2000.
- **Timing.** At 75 dpi the page is ready in 1 to 4 s and the job takes
  5 to 6 s. At 1200 dpi color Jpeg, full glass (10200 x 14032, 5.6 MB)
  the page is ready at 20 s and the download runs until 271 s, with
  data arriving all the way through while the head moves. The probe
  peaked at 84 MB resident.
- **Cancel.** A PUT with the Canceled job document during a 600 dpi
  page download returns 200. The job ends `Canceled` with
  `CanceledByDevice`, and the scanner is Idle within 2 s.
- **launchd.** `--probe-bonjour` run from a LaunchAgent registered
  `_uscan._tcp` local-only, and `dns-sd -lo -B` listed it.

## Goals

- Every HP USB printer that has an ff/cc/0 interface answering
  `/Scan/ScanCaps` shows up in Image Capture,
  Preview and other ImageCaptureCore apps, and scans. The 2336 is the
  test device.
- Everything the hardware does is reachable from Image Capture:
  every resolution, color, gray and black-and-white, the scan area,
  brightness and contrast (ToneMap), sharpening, the black-and-white
  threshold, and JPEG, PNG/TIFF (from Raw) and PDF output.
- Scanning works without the Smudge window open, from login onwards.
- Plugging and unplugging the printer adds and removes the scanner
  without user action.
- Printing and ink status keep working. A scan in progress shows in
  Smudge as "Scanning", not as an error.

## Non-goals

- A scan window inside Smudge. Image Capture is the UI.
- ADF, duplex, multi-page feeders. The tested hardware has none; a
  model whose ScanCaps lists an ADF is out of scope for now and gets
  platen only.
- The printer's own scan or copy buttons (push-to-scan).
- OCR, document detection, scan-to-email and similar extras.
- Scanners that speak SOAP/PML/SCL instead of LEDM.

## Anti-goals (a failure even if scanning works)

- The scanner is reachable from the network. The bridge listens on
  loopback only and announces only on the local-only Bonjour
  interface. Another machine on the LAN must never see it.
- Needing HP's closed plugin, a kernel extension, or a legacy ICA
  device bundle.
- Breaking printing, ink status, cleaning or alignment, or making the
  app show "printer error" because a scan holds the USB interface.
- An always-on process that wakes the printer or spins the CPU when
  nothing is scanning.

## Design

### Shape

A small per-user background agent, `smudge-scand`, does the bridging.
It is a second executable in the Swift package, built from shared code
the app also uses. (My call. The alternative was running the bridge
inside Smudge.app, but then scanning would stop whenever the app is
quit, which fails the "works like any scanner" goal.)

```
Image Capture / Preview
   |  eSCL over HTTP, 127.0.0.1:<port>, Bonjour _uscan._tcp local-only
smudge-scand  (LaunchAgent, one eSCL server per attached LEDM scanner)
   |  LEDM HTTP over USB vendor interface ff/cc/0 (IOUSBHost)
printer
```

- The LEDM transport (`LEDMUSB.swift`, the HTTP framing and reply
  reader in `LEDMClient.swift`, `USBScan`, `LEDMMatch`) moves into a
  library target both executables link. No behavior change for the
  app.
- The agent ships in the existing installer: binary under
  `/Library/Printers/smudge/bin/`, plist in `/Library/LaunchAgents/`,
  `RunAtLoad`, `KeepAlive`. It holds no USB interface while idle.
- The agent watches IOKit for HP devices arriving and leaving. On
  arrival it looks for an ff/cc/0 interface. If there is one, it
  fetches `/Scan/ScanCaps` over that interface, starts an HTTP
  listener on a free loopback port and registers the Bonjour service.
  On removal it deregisters and stops the listener. Caps are cached per
  USB serial for the life of the connection.
- Bonjour registration uses `DNSServiceRegister` with
  `kDNSServiceInterfaceIndexLocalOnly`. TXT keys as in the spike:
  `txtvers=1 vers=2.63 rs=eSCL ty=<name> pdl=<formats>
  cs=color,grayscale,binary is=platen uuid=<uuid> duplex=F`, plus
  `representation` and `note` (may be empty). The UUID is derived
  stably from the USB serial so Image Capture keeps its per-scanner
  settings across reconnects. The service name is the model name from
  ScanCaps, with the serial appended only when two of the same model
  are attached.
- The HTTP server answers only the eSCL paths below and rejects
  connections from anything that is not loopback.

### eSCL served by the agent

- `GET /eSCL/ScannerCapabilities`: built from ScanCaps. Platen caps
  with Min/Max Width/Height and MaxPhysical Width/Height from the
  platen limits, MaxScanRegions 1, discrete resolutions from
  SupportedResolutions, MaxOptical X/Y, ColorModes mapped
  `Color8 -> RGB24`, `Gray8 -> Grayscale8`, `K1 -> BlackAndWhite1`,
  ColorSpaces sRGB, the supported intents (Document, TextAndGraphic,
  Photo, Preview), DocumentFormats, and BrightnessSupport,
  ContrastSupport, SharpenSupport and ThresholdSupport when the
  matching LEDM transform is listed.
- `GET /eSCL/ScannerStatus`: `pwg:State` from `/Scan/Status`
  (`Idle -> Idle`, busy states `-> Processing`, unreachable or error
  `-> Stopped`), plus a `<scan:Jobs>` list with a `JobInfo` for every
  job the agent has open or finished in the last few minutes (see
  spike failure 2). The agent answers this from its own state and does
  not touch USB more often than once every few seconds, because Image
  Capture polls it continuously while the scanner is selected.
- `POST /eSCL/ScanJobs`: validate the settings against the caps (400
  on anything outside them), map to an LEDM job (next section), POST
  it to `/Scan/Jobs`, reply 201 with
  `Location: /eSCL/ScanJobs/<id>`. Reply 503 when the printer is busy
  printing or already scanning.
- `GET /eSCL/ScanJobs/<id>/NextDocument`: the page in the requested
  format, then 404 once the job's page has been sent. The platen
  gives one page per job.
- `DELETE /eSCL/ScanJobs/<id>`: cancel the LEDM job if it is still
  running, release the USB interface, mark the job canceled.
- `GET /eSCL/ScanJobs/<id>/ScanImageInfo` is optional.

### eSCL to LEDM mapping

The LEDM job XML, the job URL that comes back, how the page data is
fetched, and how a job is canceled follow HPLIP 3.25.2
`scan/sane/ledm.c` (the version Smudge's driver is built from). The
mapping:

| eSCL ScanSettings | LEDM ScanSettings |
|---|---|
| X/YResolution | X/YResolution (must be a listed pair) |
| ScanRegion Width/Height/X/YOffset (1/300 in) | Width/Height/XStart/YStart, same unit |
| ColorMode RGB24 / Grayscale8 / BlackAndWhite1 | ColorSpace Color / Gray / Gray |
| DocumentFormat image/jpeg | Format Jpeg (Color8, Gray8) |
| DocumentFormat image/png, image/tiff | Format Raw, encoded by the agent |
| DocumentFormat application/pdf | Jpeg (Raw for black and white), wrapped in a one-page PDF by the agent |
| BlackAndWhite1, any format | Gray, thresholded by the agent (1-bit PNG/TIFF/PDF; for JPEG, 8-bit gray) |
| Brightness, Contrast | ToneMap |
| Sharpen | software |
| Threshold | software threshold on Gray |

Adjustments use the device's own fields wherever HPLIP sends a field
for them: Brightness and Contrast in ToneMap. Sharpening and threshold
have no HPLIP field, so they are done in software, and black and white
is a Gray scan thresholded by the agent. An
adjustment with no field in `ledm.c`, or one whose field shows no
visible effect in a test scan, is applied by the agent in software on
the decoded image. Software adjustment on a Jpeg page means decode,
adjust, re-encode. The agent does not switch to Raw just for an
adjustment.
| Intent | no LEDM field; only used to pick defaults when settings are missing |

Image encoding uses ImageIO and CoreGraphics. No new dependencies.

A 1200 dpi color scan of the full glass is about 400 MB of raw
pixels. The agent streams the page from USB to a temporary file rather
than holding it in memory, and streams the file to Image Capture.

### USB sharing with the app

The agent uses only the ff/cc/0 interface, and the app uses only
255/4/1, so neither blocks the other on USB. They still coordinate
what the printer is doing:

- The agent publishes "scanning on serial X" (the shared state file
  below) and the app shows "Scanning" in the Overview status and the
  menu bar while it is set.
- Maintenance actions (clean, align) are disabled with "Scanner in
  use" while a scan runs. A scan requested while maintenance runs gets
  503.
- The agent claims the interface only per request and for the length
  of a job, never while idle.
- State goes both ways through one small file per printer serial in
  a location both processes can read and write (owner, what it is
  doing, since when, pid). The agent writes "scanning", the app writes
  "maintenance". Each side ignores an entry whose pid is gone.

### More than one logged-in user

The LaunchAgent starts in every logged-in session. Only the agent in
the active console session serves: it registers Bonjour and opens
listeners. Agents in background sessions stay silent and take over
when their session becomes the console session (fast user switching
notifications). A scan in progress finishes before the old agent lets
go. The per-user setting is read by that user's own agent.

### Printing during a scan

The agent decides "busy" from `/Scan/Status` on its own interface:
POST returns 503 when it is not Idle. The agent does not touch CUPS. A print job sent during a
scan is left to the printer, which queues it on its own interface. The
manual test list covers this overlap on the 2336. Corruption of either
job there is a stop-and-report finding, not something to work around
silently.

### Smudge app changes

- Overview shows the scanner state (ready, scanning) for printers that
  have one, and an "Open Image Capture" action.
- Settings has "Make the scanner available to Image Capture", on by
  default. Turning it off stops the agent's listener for all devices
  (the agent keeps running and reads the setting).
- `--dump` prints whether the printer has an LEDM scanner and the
  parsed caps.

## Testing

- Unit tests with the 2336's ScanCaps as a fixture: caps translation
  to eSCL, ScanSettings validation and mapping, ScannerStatus with jobs
  in each state, K1 and Raw encoding. XML is compared structurally, not
  byte for byte.
- A fake LEDM device in tests (scripted request and reply bytes) for
  the job lifecycle and cancel, so CI needs no printer.
- An ImageCaptureCore end-to-end check against the real printer:
  browse, open session, select flatbed, scan at 75 and 300 dpi in each
  color mode, and in each output format. The spike's probe did this
  against the fake scanner (it fails with -47 when Image Capture.app
  already holds the session, so quit Image Capture first).
- By hand: Image Capture overview scan, a crop, 1200 dpi color, B&W
  with threshold, PDF; Preview "Import from Scanner"; unplug mid-scan;
  print while idle-selected in Image Capture; ink and maintenance with
  the agent running.
- A check that the listener is not reachable on the LAN address and
  that the Bonjour record does not appear from another machine.

## Left to the builder

- Brightness and Contrast value ranges for ToneMap. HPLIP passes
  them through without documenting a range. Find the neutral value by
  test scans and map eSCL's range onto it.
- Repeating the Bonjour registration test under launchd. A Local
  Network prompt there moves the agent into a minimal helper app
  bundle (inside Smudge.app or its own), registered as a login item.
- Which of the spike's added capability fields Image Capture actually
  requires. Keeping all of them is fine.
- Port choice (ephemeral is fine; Bonjour carries it).
- How long finished jobs stay in the status list.

## Calls I made (not discussed)

- Bridge in a LaunchAgent, not inside the app.
- On by default, with an off switch in Settings.
- PNG/TIFF/PDF produced by the agent from Raw or Jpeg data.
- ADF-capable LEDM models get platen only for now.
- Only the console user's agent serves when several users are logged in.
- Busy detection from LEDM status only; CUPS is left alone during scans.
- Device-side adjustments where HPLIP has a field, software otherwise.
- App and agent share state through a per-serial file.
