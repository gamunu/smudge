#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Remove Smudge: the app, the filter, the PPDs, the scanner agent, the firmware
# loader and its downloaded firmware, and the installer receipt.
# Run with sudo. Printer queues are not touched; remove them first with
#   sudo lpadmin -x <queue name>
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run with sudo: sudo $0" >&2
    exit 1
fi

pkill -x "Smudge" 2>/dev/null || true

# The scanner agent runs once per logged-in user.
agentplist=/Library/LaunchAgents/io.github.gamunu.smudge.scand.plist
for uid in $(ps -axo uid=,comm= | awk '/\/loginwindow$/ {print $1}' | sort -u); do
    launchctl bootout "gui/$uid" "$agentplist" > /dev/null 2>&1 || true
done
pkill -x smudge-scand 2>/dev/null || true
rm -f "$agentplist" /tmp/smudge-scand.log

fwplist=/Library/LaunchDaemons/io.github.gamunu.smudge.firmware.plist
launchctl bootout system "$fwplist" > /dev/null 2>&1 || true
rm -f "$fwplist" /var/log/smudge-firmware.log
rm -rf /var/run/smudge-firmware.lock

rm -rf "/Applications/Smudge.app"
# Includes bin/ (the firmware tools) and firmware/ (HP's files, downloaded later).
rm -rf /Library/Printers/smudge
rm -f "/Library/Printers/PPDs/Contents/Resources/HP DeskJet 2300 series (Smudge).ppd.gz"
rm -rf /Library/Printers/PPDs/Contents/Resources/smudge
pkgutil --forget io.github.gamunu.smudge >/dev/null 2>&1 || true

# Per-user settings of the app, for the user who ran sudo.
if [ -n "${SUDO_USER:-}" ]; then
    home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
    rm -f "$home/Library/Preferences/io.github.gamunu.smudge.plist"
    rm -rf "$home/Library/Application Support/Smudge/activity" "$home/Library/Caches/Smudge/scan"
fi

echo "Smudge removed."
