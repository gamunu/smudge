#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# End-to-end scan check through ImageCaptureCore, the framework Image Capture and Preview use.
# Starts smudge-scand for one printer, then scans 75 and 300 dpi in color, gray and black and
# white, as JPEG, PNG and PDF, and checks each file's type and pixel size.
#
#   scripts/test-scan.sh SERIAL     the attached printer with this USB serial
#   scripts/test-scan.sh --demo     the built-in demo scanner, no printer needed
#
# Quit Image Capture first. It holds the scanner session and the probe fails with -47.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
target=${1:-}
[ -n "$target" ] || { echo "usage: $0 SERIAL|--demo" >&2; exit 2; }
if pgrep -x "Image Capture" > /dev/null; then
    echo "Image Capture is running. Quit it and run this again." >&2
    exit 2
fi

out=$(mktemp -d)
log="$out/scand.log"
scand_pid=
cleanup() {
    if [ -n "$scand_pid" ]; then
        kill "$scand_pid" 2> /dev/null || true
        wait "$scand_pid" 2> /dev/null || true
    fi
    rm -rf "$out"
}
trap cleanup EXIT

(cd "$root/app" && swift build --product smudge-scand > /dev/null)
bin="$(cd "$root/app" && swift build --product smudge-scand --show-bin-path)/smudge-scand"
mkdir -p "$root/build"
swiftc -O "$root/tests/scan-probe.swift" -o "$root/build/scan-probe" 2> /dev/null

if [ "$target" = "--demo" ]; then
    "$bin" --serve --demo 2> "$log" &
else
    "$bin" --serve --serial "$target" 2> "$log" &
fi
scand_pid=$!

name=
for _ in $(seq 1 50); do
    name=$(sed -n 's/^serving \(.*\) on 127\.0\.0\.1:[0-9]*$/\1/p' "$log" | head -n 1)
    [ -z "$name" ] || break
    sleep 0.2
done
[ -n "$name" ] || { echo "smudge-scand did not start:" >&2; cat "$log" >&2; exit 1; }
echo "scanner: $name"

fail=0
for res in 75 300; do
    for mode in color gray bw; do
        for fmt in jpeg png pdf; do
            dir="$out/$res-$mode-$fmt"
            if ! line=$("$root/build/scan-probe" --name "$name" --res "$res" --mode "$mode" --format "$fmt" \
                --out "$dir" --timeout 180 2>&1 | grep '^file='); then
                echo "FAIL $res dpi $mode $fmt: no file"
                fail=1
                continue
            fi
            path=${line#file=}; path=${path%% area=*}
            area=${line##* area=}
            want=$(( ${area%x*} * res / 300 ))
            desc=$(file -b "$path")
            case "$fmt" in
                jpeg) want_type="JPEG image data" ;;
                png) want_type="PNG image data" ;;
                pdf) want_type="PDF document" ;;
            esac
            case "$desc" in
                "$want_type"*) ;;
                *) echo "FAIL $res dpi $mode $fmt: type is '$desc'"; fail=1; continue ;;
            esac
            if [ "$fmt" != pdf ]; then
                got=$(sips -g pixelWidth "$path" | awk '/pixelWidth/ {print $2}')
                diff=$(( got > want ? got - want : want - got ))
                if [ "$diff" -gt 2 ]; then
                    echo "FAIL $res dpi $mode $fmt: width $got, want $want"
                    fail=1
                    continue
                fi
            fi
            echo "ok   $res dpi $mode $fmt"
        done
    done
done
exit "$fail"
