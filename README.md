<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Smudge icon">
</p>

<h1 align="center">Smudge</h1>

<p align="center">
  A working Mac driver and a friendly status app for HP printers over USB.<br>
  Built from HP's own open-source code, because HP would not ship one.
</p>

<p align="center">
  <a href="https://github.com/gamunu/smudge/actions/workflows/ci.yml"><img src="https://github.com/gamunu/smudge/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/gamunu/smudge/actions/workflows/codeql.yml"><img src="https://github.com/gamunu/smudge/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="https://github.com/gamunu/smudge/releases/latest"><img src="https://img.shields.io/github/v/release/gamunu/smudge?include_prereleases&sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--or--later-blue" alt="License: AGPL-3.0-or-later"></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-black" alt="macOS on Apple Silicon">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="760" alt="The Overview screen showing the printer ready, ink levels and quick actions">
</p>

## Why this exists

I plugged a DeskJet 2300 into a Mac with a USB cable. The Mac saw it straight away. It just would not print.

macOS has no driver for this model. The printer has no AirPrint over USB, so the driverless path is closed too. The generic drivers macOS offers send garbage, or nothing.

HP's answer was its app. The app only looks for printers on Wi-Fi or Ethernet. This printer has neither. HP Easy Start searched and said it could not find any software for the product.

Apple's HP driver package is from 2020. It does not include this model, and its installer refuses to run on anything newer than macOS 12.

HP does publish a driver that supports this printer. It is called HPLIP, it is open source, and it only builds for Linux. So this project builds it for the Mac.

## A note to HP

You sold this printer with a USB port and a scanner on top. Then you made sure a Mac owner could use neither.

- No macOS driver. Not an old one, not a broken one. None.
- An app that cannot see a USB printer at all.
- An "Easy Start" that searches, finds nothing, and links to a support page.
- Head cleaning, alignment and ink levels locked behind software that does not exist for this printer on this platform.
- A working driver you wrote yourselves, sitting in HPLIP under an open license, that you never built for the Mac.

Every one of those features was already in the printer. It answers ink and maintenance requests over its own USB cable. You just never wrote the Mac side.

Getting one page out of it cost me an evening. This repository is the Mac side you skipped.

Fuck you, HP.

## What you get

**A real print driver.** The `hpcups` filter from HPLIP 3.25.2, built natively for Apple Silicon. It links only against macOS system libraries and installs where the Mac print system expects it.

**A status app** with a Dock icon, a main window and a menu bar item.

- Printer state in plain words: ready, printing, needs paper, door open, unplugged.
- Ink levels for the black and tri-color cartridges, read from the printer itself.
- Your print jobs, with cancel and pause.
- Guided cleaning, deep cleaning, a diagnostics page and head alignment, with pictures for every step.

**Scanning** in Image Capture and Preview, from 75 to 1200 dpi, in color, gray or black and white. Smudge makes the printer look like an AirScan scanner, but only to your own Mac.

<p align="center">
  <img src="docs/images/ink.png" width="760" alt="The Ink screen with the black cartridge at 100 percent and tri-color at 90 percent">
</p>

## Install

Paste this into Terminal:

    curl -fsSL https://raw.githubusercontent.com/gamunu/smudge/main/install.sh | sh

The script downloads the latest release, checks it against the release's `SHA256SUMS`, and installs it with Apple's `installer` command. It asks for your Mac password once.

Then plug in the printer, open **System Settings > Printers & Scanners**, click **Add Printer**, pick your HP printer, and set **Use** to the "..., Smudge" driver.

### With Homebrew

    brew tap gamunu/tap
    brew trust gamunu/tap
    brew install --cask smudge

Homebrew also installs the package with `installer`, so there is no prompt. `brew upgrade` and the app's own updates both work.

### Installing the .pkg by hand

The package is not signed with a paid Apple Developer ID, so macOS says it "could not verify" it when you open it from Finder. To install it anyway:

1. Download `smudge-<version>.pkg` from the [latest release](https://github.com/gamunu/smudge/releases/latest) and double-click it.
2. Click **Done** on the warning. Do not move it to the Bin.
3. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to the package name.

Right click > Open no longer skips this check on macOS 15 and later. Updates from inside the app are checked against this project's signing key and do not show the warning.

The package installs the filter, a PPD for each supported printer, and `/Applications/Smudge.app`. It does not add the printer for you.

From a shell, the same steps are:

    sudo installer -pkg smudge-<version>.pkg -target /
    lpinfo -v | grep -i usb
    sudo lpadmin -p HP_DeskJet_2300 -E -v "<usb uri from lpinfo>" \
        -P "/Library/Printers/PPDs/Contents/Resources/HP DeskJet 2300 series (Smudge).ppd.gz"

### LaserJets that need firmware

The LaserJet 1000, 1005, 1018, 1020, P1005 to P1009, P1505 and P1566 keep no firmware in flash. After every power-on they need HP's firmware sent over USB before they print. HP does not allow the firmware to be redistributed, so the package does not carry it. Download it once from HP's own HPLIP 3.25.2 plugin:

    sudo /Library/Printers/smudge/bin/smudge-fetch-firmware

The script checks the download against a pinned SHA-256 and unpacks only the `hp_laserjet_*.fw.gz` files into `/Library/Printers/smudge/firmware`. It never runs anything from the plugin.

The package also installs a LaunchDaemon, `io.github.gamunu.smudge.firmware`. launchd starts `smudge-firmware-load` when one of these printers appears on USB. It reads the printer's IEEE-1284 device ID through Apple's `usb` backend. A device ID without `FWVER` means no firmware is running, so the loader sends the file for that model through the same backend. A printer that already runs firmware is left alone. Give the printer a few seconds after power-on before the first job. Progress goes to `/var/log/smudge-firmware.log`. The queue is a plain `usb://` queue, added with `lpadmin` as above, using the PPD for your model. To load firmware by hand, run `sudo /Library/Printers/smudge/bin/smudge-firmware-load`.

## Using the app

Open **Smudge** from Applications. The Overview tells you whether the printer is ready and what to do if it is not.

### Faint or streaky prints

1. Go to **Maintenance** and run **Clean print heads**. Load blank paper first.
2. Run **Print diagnostics page** and look at it. The app tells you what to do next.
3. Still faint after a deep clean? Take the cartridge out and wipe its copper contacts with a dry, soft cloth.

That last step is what brought a "dead" black cartridge back during testing. It was full of ink. Dried ink on the contacts stopped the nozzles from firing.

<p align="center">
  <img src="docs/images/diagnostics-check.png" width="760" alt="The diagnostics step asking how the page looked, with advice for each answer">
</p>

### Lining up the print heads

**Line up print heads** prints a page, then walks you through scanning it. Lift the lid, put the page face down in the marker corner, close the lid, press **Color Copy**. The app follows the printer and highlights the step it is waiting for.

<p align="center">
  <img src="docs/images/align-scan.png" width="760" alt="The alignment scan step with four numbered picture cards">
</p>

Every running task has a **Cancel** button. If the printer gets stuck waiting for a scan, the Overview and the menu bar offer **Cancel alignment**.

### Scanning

Put the page face down on the glass and open **Image Capture**, or use **File > Import from Scanner** in Preview. The printer shows up under **Shared** with its full name, for example "DeskJet Ink Advantage 2300 All-in-One Printer series". The Overview's **Scanner** card has an **Open Image Capture** button.

Image Capture makes a quick overview scan when you pick the printer. Choose the area, then set the options under **Show Details**:

- **Resolution:** 75, 100, 200, 300, 600 or 1200 dpi. A full page takes about 5 seconds at 75 dpi, 20 seconds at 300 dpi and 4.5 minutes at 1200 dpi.
- **Kind:** color, gray, or black and white.
- **Format:** JPEG, PNG, TIFF or PDF.

The glass takes one page at a time, up to US Letter width and A4 length. There is no document feeder.

While a scan runs, the Overview says **Scanning** and cleaning and alignment wait for it to finish. You can still print. Unplug the printer and the scanner leaves Image Capture. Plug it back in and it returns a few seconds later.

The scanner is visible only on this Mac. Nothing listens on your network, and other computers cannot see it. To hide it from Image Capture and Preview, turn off **Make the scanner available to Image Capture and Preview** in Smudge's Settings.

Apps other than Image Capture and Preview that ask macOS directly for a JPEG file get an uncompressed TIFF saved under a `.jpeg` name. Image Capture and Preview save real JPEGs.

## Supported printers

857 HPLIP PPD files, covering about 2,300 HP model names: DeskJet, Envy, Smart Tank, OfficeJet, PSC, Photosmart, Business Inkjet, Neverstop and a set of LaserJet and Color LaserJet models. They speak twelve print languages: PCL3GUI2 (362 files), LaserJet PCL (128), PCL3GUI (82), LaserJet color PCL (65), PCL3 (64), LIDIL (51), ZjStream (43, JBIG), HBPL1 (42, PCLm output), ZxStream (10, JBIG), JetReady (5), QuickConnect (3) and PCLXL fast raster (2). The full list, one row per model with its language, is in [docs/supported-printers.md](docs/supported-printers.md). It is generated by `scripts/gen-ppds.py`.

Only the DeskJet 2300 series has been tested on real hardware. The rest are checked offline: every PPD passes `cupstestppd`, and `make test` runs the filter once per language and checks the bytes it writes. A model in the list can still print wrong, and the status app only knows the 2300.

None of these needs HP's closed plugin. For most models the plugin only adds scanning, fax or faster printing.

Scanning works with any HP USB printer whose scanner speaks LEDM, the same protocol as the ink readout, on its own USB interface (class 255, subclass 204, protocol 0). Only the DeskJet 2300 series has been tested. The one part printing needed, the JBIG compressor for ZjStream and ZxStream LaserJets, is replaced by jbigkit, with the same settings foo2zjs uses for these printers. The LaserJets that need firmware after every power-on get it from HP's plugin file, downloaded on your Mac (see [LaserJets that need firmware](#laserjets-that-need-firmware)). 3 PPD files are left out: the LaserJet Professional P1567, P1568 and P1569, for which HP's plugin has no firmware. `ppd/hplip/excluded.tsv` has every excluded file with its reason.

Printers are added in **System Settings > Printers & Scanners** as before. The PPDs are in `/Library/Printers/PPDs/Contents/Resources/smudge/`.

## How it works

**Printing.** CUPS turns your document into raster pages and hands them to `hpcups`, which encodes them as PCL3GUI for the printer. The filter is HPLIP's code with HP's prebuilt image library and dbus left out. `src/hpcups/UPSTREAM` lists the changes.

**Ink and maintenance.** The printer has a second USB interface (class 255, subclass 4, protocol 1) with a small web server on it. HP calls it LEDM. HPLIP uses it on Linux. The app claims that interface through IOUSBHost and sends HTTP requests to it.

CUPS keeps the printing interface, so the two never fight over the cable.

This printer answers slowly, and a reply can arrive after the next request has gone out. The client sends one request at a time, drains leftover bytes, reads the full reply and checks the XML root matches what it asked for.

**Scanning.** The scanner has a third USB interface (class 255, subclass 204, protocol 0) that speaks LEDM too, under `/Scan`. A small background helper, `smudge-scand`, runs in your login session as the LaunchAgent `io.github.gamunu.smudge.scand`. When a printer with that interface appears, it serves eSCL, the protocol behind AirScan, on `127.0.0.1` and announces it with Bonjour on the local-only interface. Image Capture's own AirScan support finds it there. Each scan job becomes an LEDM job over USB.

The helper asks the printer for raw pixels and streams them to Image Capture as an uncompressed TIFF of known size, row by row as the printer scans. Image Capture measures its progress bar against the size of an uncompressed image, so a streamed JPEG would leave the bar nearly empty until the end. Raw is no slower than JPEG on this printer. Formats that need the whole page first, and sharpening, wait for the page and ask Image Capture to retry until it is ready. The design, and what was measured on the printer, is in [docs/superpowers/specs/2026-10-30-scanning-design.md](docs/superpowers/specs/2026-10-30-scanning-design.md).

The scanner uses its own interface, so scanning, printing and the ink readout never wait for each other over USB.

Alignment on this model goes Printing, ScanRequested, Scanning, then back to ready. It never reports "CalibrationValid", even after a good alignment, so the app treats a pass through Scanning as done.

## Build from source

You need Xcode and `brew install jpeg-turbo pkgconf`.

    make                   # the hpcups filter in build/hpcups
    make test              # renders pages offline and checks the PCL output
    cd app && swift test   # unit tests for the app's printer logic
    scripts/build-app.sh   # build/app.noindex/Smudge.app
    make pkg               # build/smudge-<version>.pkg

`build/app.noindex/Smudge.app/Contents/MacOS/Smudge --dump` prints the printer state, ink and job list as text. `--ledm-get <path>` prints one raw printer document. `--preview-step <name>` opens a maintenance step with fake data, so you can look at the screens without printing.

`smudge-scand --probe --res 75 --out <dir>` runs one scan straight over USB and logs every LEDM request. `smudge-scand --serve --demo` serves a fake scanner to Image Capture without a printer. The installed helper logs scan jobs to `~/Library/Logs/Smudge/smudge-scand.log`.

## Releases and updates

The app checks for updates with Sparkle once a day, and **Check for Updates...** is in the app menu. An update is the same `.pkg` as a fresh install, so the driver and the app move together.

Releases come from [release-please](https://github.com/googleapis/release-please). Nobody tags by hand.

1. Merge pull requests into `main` with Conventional Commit messages. `fix:` bumps the patch version, `feat:` the minor version, and a `!` or `BREAKING CHANGE:` the major version.
2. release-please keeps a "chore(main): release x.y.z" pull request open with the next version and the `CHANGELOG.md` entry.
3. Merging that pull request tags `vX.Y.Z` and creates the GitHub Release. The release workflow then builds the package, signs it for Sparkle, writes `appcast.xml` and attaches both.

### One-time setup for maintainers

Do this before the first release. A build without the public key can never verify an update, so its users would have to reinstall by hand.

    scripts/build-app.sh
    BIN="$PWD/app/.build/artifacts/sparkle/Sparkle/bin"
    "$BIN/generate_keys"
    "$BIN/generate_keys" -x /tmp/sparkle_private_key
    gh secret set SPARKLE_PRIVATE_KEY --repo gamunu/smudge < /tmp/sparkle_private_key
    rm /tmp/sparkle_private_key
    gh variable set SPARKLE_PUBLIC_KEY --repo gamunu/smudge --body "$("$BIN/generate_keys" -p)"

Back the private key up in a password manager. Lose it and every installed copy needs a manual reinstall.

## Uninstall

    sudo lpadmin -x HP_DeskJet_2300
    sudo scripts/uninstall.sh

This removes the app, the filter, the PPDs, the scanner helper and its LaunchAgent, the firmware loader (its LaunchDaemon and `/Library/Printers/smudge/bin`), any firmware downloaded to `/Library/Printers/smudge/firmware`, and the installer receipt.

## License

Smudge is AGPL-3.0-or-later. See [LICENSE](LICENSE).

HP's files in `src/hpcups/` and `src/common/` keep their own headers: BSD-style, MIT, or GPL-2.0-or-later. All three can be combined into an AGPL-3.0-or-later work. [LICENSING.md](LICENSING.md) lists which file carries which license. HPLIP's license text is in [COPYING](COPYING).

## Thanks

To the HPLIP developers, for writing and publishing the driver HP itself would not ship for the Mac. Every page this printer prints on a Mac goes through their code.
