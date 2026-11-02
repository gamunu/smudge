#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Make the PPD set and the seed corpus for tests/fuzz/fuzz-raster.cpp in $1.
# One PPD per print language (the same ones scripts/test-local.sh uses), and
# for each a text page rendered to CUPS raster with cupsfilter. Seeds are cut
# to 64 KiB: the header and the first rows are where the filter sizes its
# buffers, and short inputs keep the fuzzer fast. The first seed byte is the
# PPD index the harness uses.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=$1
mkdir -p "$out/ppds" "$out/seeds" "$out/corpus"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 -I "$root/scripts/gen-ppds.py" build --out "$tmp/ppds" > /dev/null
printf 'Smudge fuzz seed\nThe quick brown fox jumps over the lazy dog.\n' > "$tmp/page.txt"

names="hp-deskjet_2300_series hp-2000c apollo-2100 hp-910 hp-laserjet_1015
hp-business_inkjet_2300-pcl3 hp-laserjet_1010 hp-color_laserjet_pro_mfp_m177fw
hp-color_laserjet_3500 hp-photosmart_a530_series hp-laserjet_professional_p1102
hp-laserjet_p2014-zxs"

for name in $names; do
    if [ "$name" = hp-deskjet_2300_series ]; then
        gz="$tmp/ppds/HP DeskJet 2300 series (Smudge).ppd.gz"
    else
        gz="$tmp/ppds/smudge/$name.ppd.gz"
    fi
    gzip -dc "$gz" > "$out/ppds/$name.ppd"
done

i=0
for ppd in $(cd "$out/ppds" && ls ./*.ppd | sort); do
    ppd=${ppd#./}
    cupsfilter -p "$out/ppds/$ppd" -m application/vnd.cups-raster "$tmp/page.txt" \
        > "$tmp/page.ras" 2> /dev/null
    { printf "\\$(printf '%03o' "$i")"; head -c 65536 "$tmp/page.ras"; } > "$out/seeds/${ppd%.ppd}"
    i=$((i + 1))
done
echo "seeded $i languages in $out"
