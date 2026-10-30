#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Build one unsigned installer package into build/. Does not install anything.
# It installs the CUPS driver (filter and PPDs), the firmware tools for the
# LaserJets that need firmware after every power-on, the scanner agent, and /Applications/Smudge.app.
# The version comes from scripts/version.sh (VERSION env, git tag vX.Y.Z, VERSION file).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=$("$root/scripts/version.sh")
id=io.github.gamunu.smudge
stage="$root/build/pkgroot.noindex"
out="$root/build/smudge-$version.pkg"
app="Smudge.app"

[ -x "$root/build/hpcups" ] || make -C "$root"
VERSION=$version "$root/scripts/build-app.sh"

rm -rf "$stage" "$root/build/component.pkg" "$root/build/component.plist"
mkdir -p "$stage/Library/Printers/smudge/filter" \
         "$stage/Library/Printers/smudge/bin" \
         "$stage/Library/LaunchDaemons" \
         "$stage/Library/LaunchAgents" \
         "$stage/Library/Printers/PPDs/Contents/Resources" \
         "$stage/Applications"

install -m 755 "$root/build/hpcups" "$stage/Library/Printers/smudge/filter/hpcups"
# Firmware tools. HP's firmware is not shipped; smudge-fetch-firmware downloads it.
install -m 755 "$root/scripts/fetch-firmware.sh" "$stage/Library/Printers/smudge/bin/smudge-fetch-firmware"
install -m 755 "$root/scripts/smudge-firmware-load" "$stage/Library/Printers/smudge/bin/smudge-firmware-load"
install -m 644 "$root/scripts/io.github.gamunu.smudge.firmware.plist" "$stage/Library/LaunchDaemons/"
# Scanner agent: serves attached HP scanners to Image Capture over loopback.
install -m 755 "$root/build/app.noindex/smudge-scand" "$stage/Library/Printers/smudge/bin/smudge-scand"
install -m 644 "$root/scripts/io.github.gamunu.smudge.scand.plist" "$stage/Library/LaunchAgents/"
pkgscripts="$root/build/pkgscripts"
rm -rf "$pkgscripts"
mkdir -p "$pkgscripts"
install -m 755 "$root/scripts/pkg-postinstall" "$pkgscripts/postinstall"
# One PPD per HPLIP model family, rewritten for macOS. The DeskJet 2300 keeps
# its old top-level path; the rest go in a subfolder.
ppds="$stage/Library/Printers/PPDs/Contents/Resources"
python3 -I "$root/scripts/gen-ppds.py" build --out "$ppds"
python3 -I "$root/scripts/gen-ppds.py" check "$ppds"
find "$ppds" -type f -exec chmod 644 {} +
find "$ppds" -type d -exec chmod 755 {} +
cp "$root/COPYING" "$root/LICENSE" "$root/LICENSING.md" "$stage/Library/Printers/smudge/"
ditto --norsrc "$root/build/app.noindex/$app" "$stage/Applications/$app"

xattr -cr "$stage"
export COPYFILE_DISABLE=1

# Keep the app at /Applications. Without this, Installer updates any copy of
# the bundle it finds elsewhere on the disk.
pkgbuild --analyze --root "$stage" "$root/build/component.plist" >/dev/null
# Only the top-level bundle (index 0) needs the flag.
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$root/build/component.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$root/build/component.plist"

# --ownership recommended makes the installer set root:wheel on install.
pkgbuild --root "$stage" \
         --component-plist "$root/build/component.plist" \
         --identifier "$id" \
         --version "$version" \
         --ownership recommended \
         --scripts "$pkgscripts" \
         --install-location / \
         "$root/build/component.pkg"

# The distribution file gives the Installer a title and a license pane.
res="$root/build/pkgres"
rm -rf "$res"
mkdir -p "$res"
cp "$root/LICENSE" "$res/LICENSE.txt"
cat > "$root/build/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Smudge $version</title>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Smudge (AGPL-3.0-or-later)">
        <pkg-ref id="$id"/>
    </choice>
    <pkg-ref id="$id" version="$version">component.pkg</pkg-ref>
</installer-gui-script>
DIST
productbuild --distribution "$root/build/distribution.xml" \
             --resources "$res" \
             --package-path "$root/build" \
             "$out"
rm -rf "$root/build/component.pkg" "$root/build/component.plist" "$root/build/distribution.xml" "$res" "$pkgscripts"
echo "built $out"
