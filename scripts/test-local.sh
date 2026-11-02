#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Offline test, no printer needed.
#  0. The firmware loader (scripts/test-firmware.sh).
#  1. Build every PPD and check them (keywords, filter path, cupstestppd).
#  2. For each print language we serve, render a text page to CUPS raster with
#     macOS cupsfilter, run it through build/hpcups with one representative
#     PPD, and check the output for that language's header bytes.
#  3. Two page job on the DeskJet 2300 (PCL3GUI2).
#  Set HPCUPS to test another filter binary (make asan does).
#  The filter output for the fixed test page is hashed per language and
#  compared with tests/golden/outputs.sha256. Job times, host and date are
#  masked first. Run with UPDATE_GOLDEN=1 to rewrite the file after a
#  change that is meant to alter the output.
#  The ZjStream and ZxStream languages also get their JBIG data checked: the
#  built-in encoder is round tripped through jbigkit's decoder
#  (tests/jbigrt.c), and the JBIG image in each filter output is cut out and
#  decoded (tests/jbigdec.c). Set FOO2ZJS and FOO2XQX to the paths of those
#  foo2zjs tools to also compare the encoder output with theirs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
filter=$(cd "$(dirname "${HPCUPS:-$root/build/hpcups}")" && pwd)/$(basename "${HPCUPS:-$root/build/hpcups}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

golden="$root/tests/golden/outputs.sha256"
mkdir "$tmp/golden"

[ -x "$filter" ] || { echo "missing $filter, run make first" >&2; exit 1; }

# ---- 0. the firmware loader ----
"$root/scripts/test-firmware.sh"

# ---- 1. the PPD set ----
ppds="$tmp/ppds"
python3 -I "$root/scripts/gen-ppds.py" build --out "$ppds" > /dev/null
python3 -I "$root/scripts/gen-ppds.py" check "$ppds" \
    || { echo "FAIL: PPD keyword check" >&2; exit 1; }
# The 2300 PPD must stay byte for byte what earlier packages installed.
legacy="$ppds/HP DeskJet 2300 series (Smudge).ppd.gz"
[ -f "$legacy" ] || { echo "FAIL: legacy DeskJet 2300 PPD path is gone" >&2; exit 1; }

command -v cupstestppd > /dev/null \
    || { echo "FAIL: cupstestppd not found" >&2; exit 1; }
find "$ppds" -name '*.ppd.gz' -print0 \
    | xargs -0 -n 1 -P 8 sh -c '
        f=$(mktemp "${TMPDIR:-/tmp}/ppdchk.XXXXXX")
        gzip -dc "$1" > "$f"
        cupstestppd -q -W translations -I filters "$f" > /dev/null 2>&1 || echo "$1"
        rm -f "$f"' _ > "$tmp/ppd-fail.txt"
if [ -s "$tmp/ppd-fail.txt" ]; then
    echo "FAIL: cupstestppd -W translations rejected:" >&2
    head -20 "$tmp/ppd-fail.txt" >&2
    exit 1
fi
count=$(find "$ppds" -name '*.ppd.gz' | wc -l | tr -d ' ')
echo "PASS: $count PPDs pass cupstestppd -W translations and point at the installed filter"

# ---- 1b. the JBIG encoder, on its own ----
mkdir "$tmp/jbig"
cc -O1 -w -I"$root/src/jbigkit" -I"$root/src/hpcups" -o "$tmp/jbig/jbigrt" \
    "$root/tests/jbigrt.c" "$root/src/compat/hp_jbig.c" \
    "$root/src/jbigkit/jbig.c" "$root/src/jbigkit/jbig_ar.c"
cc -O1 -w -I"$root/src/jbigkit" -o "$tmp/jbig/jbigdec" \
    "$root/tests/jbigdec.c" "$root/src/jbigkit/jbig.c" "$root/src/jbigkit/jbig_ar.c"
"$tmp/jbig/jbigrt" > "$tmp/jbig/rt.log" \
    || { grep -v '^ok' "$tmp/jbig/rt.log" >&2; echo "FAIL: JBIG encoder round trip" >&2; exit 1; }
echo "PASS: JBIG encoder round trips $(grep -c '^ok' "$tmp/jbig/rt.log") bitmaps through jbigkit's decoder"

# ---- 2. one job per print language ----
# Render $2 (a text file) to raster for PPD file $1, filter it, and leave the
# output in $tmp/out.bin and the filter log in $tmp/hpcups.log.
run_filter() {
    ppd=$1
    txt=$2
    cupsfilter -p "$ppd" -m application/vnd.cups-raster "$txt" \
        > "$tmp/page.ras" 2> "$tmp/cupsfilter.log" \
        || { cat "$tmp/cupsfilter.log" >&2; echo "FAIL: cupsfilter" >&2; exit 1; }
    [ -s "$tmp/page.ras" ] || { echo "FAIL: empty raster" >&2; exit 1; }

    # argv: job user title copies options
    PPD="$ppd" TMPDIR="$tmp" "$filter" 1 smudge "local test" 1 "" \
        < "$tmp/page.ras" > "$tmp/out.bin" 2> "$tmp/hpcups.log" \
        || { cat "$tmp/hpcups.log" >&2; echo "FAIL: hpcups exit status" >&2; exit 1; }
}

has() { LC_ALL=C grep -aqF -- "$1" "$tmp/out.bin"; }
starts() { [ "$(head -c "${#1}" "$tmp/out.bin")" = "$1" ]; }

ESC=$'\x1b'
UEL="${ESC}%-12345X"

# Expected bytes per language, checked against the whole output unless the
# check says "starts".
check_language() {
    lang=$1
    case $lang in
    pcl3gui2|pcl3gui)
        starts "${ESC}E${UEL}" && has '@PJL ENTER LANGUAGE=PCL3GUI' ;;
    pcl3)
        starts "${ESC}E${UEL}${ESC}&l" ;;
    lidil)
        # LIDIL sync: 0x24 0x01 0x00 0x00 0x07
        [ "$(head -c 5 "$tmp/out.bin" | xxd -p)" = '2401000007' ] ;;
    ljmono|ljcolor)
        starts "${ESC}E${UEL}@PJL" && has '@PJL ENTER LANGUAGE=PCL' ;;
    ljfastraster)
        starts "${ESC}E${UEL}@PJL" && has '@PJL ENTER LANGUAGE=PCLXL' ;;
    ljjetready)
        # PCLXL job. The JPEG start of image is cut off (the quant tables go
        # out in their own block), so there is no marker to look for.
        starts "${ESC}E${UEL}@PJL" && has '@PJL ENTER LANGUAGE=PCLXL' && has 'JetReady generator' ;;
    quickconnect)
        has '@PJL ENTER LANGUAGE=PHOTOJPEG' && has $'\xff\xd8\xff' ;;
    ljzjstream)
        starts "${ESC}E${UEL}@PJL ENTER LANGUAGE=ZJS" ;;
    ljzxstream)
        starts "${ESC}E${UEL}" && has ',XQX' && has '@PJL EOJ' ;;
    hbpl1)
        # The filter writes PCLm, which is a PDF with a PCLm comment.
        starts '%PDF-' && has '%PCLm' ;;
    *) return 1 ;;
    esac
}

# Cut the JBIG image out of $tmp/out.bin for language $1 and decode it. The
# ZjStream start-page chunk says how big the page is, so that has to match.
check_jbig() {
    lang=$1
    kind=zjs
    [ "$lang" = ljzxstream ] && kind=zxs
    python3 -I "$root/scripts/extract-jbig.py" "$kind" "$tmp/out.bin" "$tmp/jbig/$lang-" \
        > "$tmp/jbig/$lang.txt" \
        || { echo "FAIL: $lang: cannot read the JBIG stream" >&2; exit 1; }
    [ "$(wc -l < "$tmp/jbig/$lang.txt" | tr -d ' ')" -eq 1 ] \
        || { echo "FAIL: $lang: expected one JBIG image for one page" >&2; exit 1; }
    read -r -a fields < "$tmp/jbig/$lang.txt"
    set -- "${fields[@]}"
    want_x=$2
    want_y=$3
    "$tmp/jbig/jbigdec" "$tmp/jbig/$lang-1.jbg" "$tmp/jbig/$lang-1.raw" > "$tmp/jbig/$lang-dec.txt" \
        || { echo "FAIL: $lang: jbigkit cannot decode the page image" >&2; exit 1; }
    read -r -a fields < "$tmp/jbig/$lang-dec.txt"
    set -- "${fields[@]}"
    [ "$#" -eq 3 ] || { echo "FAIL: $lang: jbigdec printed no size" >&2; exit 1; }
    if [ "$kind" = zjs ]; then
        [ "$1" = "$want_x" ] && [ "$2" = "$want_y" ] \
            || { echo "FAIL: $lang: image is $1x$2, start-page chunk says ${want_x}x$want_y" >&2; exit 1; }
    fi
    [ "$3" -gt 0 ] || { echo "FAIL: $lang: decoded page is blank" >&2; exit 1; }
    echo "PASS: $lang JBIG image decodes to $1 x $2 pixels, $3 set"

    # The same bitmap through foo2zjs/foo2xqx must give the same JBIG stream.
    tool=${FOO2ZJS:-}
    args="-r600x600 -p1"
    if [ "$kind" = zxs ]; then
        tool=${FOO2XQX:-}
        args="-r1200x600 -p1"
    fi
    if [ -n "$tool" ]; then
        { printf 'P4\n%s %s\n' "$1" "$2"; cat "$tmp/jbig/$lang-1.raw"; } > "$tmp/jbig/$lang.pbm"
        # shellcheck disable=SC2086
        "$tool" $args < "$tmp/jbig/$lang.pbm" > "$tmp/jbig/$lang-ref.bin" 2> /dev/null \
            || { echo "FAIL: $tool failed" >&2; exit 1; }
        python3 -I "$root/scripts/extract-jbig.py" "$kind" "$tmp/jbig/$lang-ref.bin" \
            "$tmp/jbig/$lang-ref-" > /dev/null
        python3 -I -c '
import sys
a = open(sys.argv[1], "rb").read().rstrip(b"\0")
b = open(sys.argv[2], "rb").read().rstrip(b"\0")
sys.exit(0 if a == b else 1)' "$tmp/jbig/$lang-1.jbg" "$tmp/jbig/$lang-ref-1.jbg" \
            || { echo "FAIL: $lang: JBIG stream differs from $(basename "$tool")" >&2; exit 1; }
        echo "PASS: $lang JBIG stream is byte for byte what $(basename "$tool") writes"
    fi
}

# Golden output check. tests/golden/outputs.sha256 has one line per language:
# the language, the SHA-256 of the raster cupsfilter made and the SHA-256 of
# the masked filter output. A different raster means the macOS renderer
# changed, so the output hash says nothing and the check is skipped.
golden_mask() {
    python3 -I -c '
import re, sys
d = open(sys.argv[1], "rb").read()
for pat, rep in (
    (rb"Job Start Time: [^\"]*", b"Job Start Time: T"),
    (rb"job-start-time: [^\r\n]*", b"job-start-time: T"),
    (rb"JobAcct2=[^\"\r\n]*", b"JobAcct2=H"),
    (rb"JobAcct4=[0-9]+", b"JobAcct4=N"),
    (rb"TIMESTAMP=[0-9]+", b"TIMESTAMP=N"),
    (rb"(App Filename: [^;]*; )[0-9]+-[0-9]+-[0-9]+", rb"\1D"),
):
    d = re.sub(pat, rep, d)
open(sys.argv[2], "wb").write(d)' "$1" "$2"
}

golden_check() {
    lang=$1
    name=$2
    # PCLm is a PDF whose xref offsets move with the length of the job start time.
    [ "$lang" = hbpl1 ] && return 0
    golden_mask "$tmp/out.bin" "$tmp/golden/out.norm"
    ras_sum=$(shasum -a 256 < "$tmp/page.ras" | cut -d' ' -f1)
    out_sum=$(shasum -a 256 < "$tmp/golden/out.norm" | cut -d' ' -f1)
    if [ -n "${UPDATE_GOLDEN:-}" ]; then
        echo "$lang $ras_sum $out_sum" >> "$tmp/golden/new"
        return 0
    fi
    want=$(awk -v l="$lang" '$1 == l { print $2, $3 }' "$golden")
    [ -n "$want" ] \
        || { echo "FAIL: golden: no hash for $lang, run UPDATE_GOLDEN=1 scripts/test-local.sh" >&2; exit 1; }
    if [ "${want% *}" != "$ras_sum" ]; then
        echo "SKIP: golden: $lang ($name): cupsfilter made a different raster than the recorded one"
        return 0
    fi
    [ "${want#* }" = "$out_sum" ] \
        || { echo "FAIL: golden: $lang ($name): filter output changed (got $out_sum, want ${want#* }); if intended run UPDATE_GOLDEN=1 scripts/test-local.sh" >&2; exit 1; }
}

printf 'Smudge local test page\nThe quick brown fox jumps over the lazy dog.\n' > "$tmp/page.txt"

# language:PPD basename. Every language in ppd/hplip/manifest.tsv needs a row.
reps="pcl3gui2:hp-deskjet_2300_series
pcl3gui:hp-2000c
pcl3:apollo-2100
lidil:hp-910
ljmono:hp-laserjet_1015
ljcolor:hp-business_inkjet_2300-pcl3
ljfastraster:hp-laserjet_1010
hbpl1:hp-color_laserjet_pro_mfp_m177fw
ljjetready:hp-color_laserjet_3500
quickconnect:hp-photosmart_a530_series
ljzjstream:hp-laserjet_professional_p1102
ljzxstream:hp-laserjet_p2014-zxs"

for lang in $(grep -v '^#' "$root/ppd/hplip/manifest.tsv" | cut -f2 | sort -u); do
    echo "$reps" | grep -q "^$lang:" \
        || { echo "FAIL: no test PPD for language $lang" >&2; exit 1; }
done

pcl3gui2_ppd=""
for row in $reps; do
    lang=${row%%:*}
    name=${row##*:}
    got=$(awk -F'\t' -v p="$name.ppd" '$1 == p { print $2 }' "$root/ppd/hplip/manifest.tsv")
    [ "$got" = "$lang" ] \
        || { echo "FAIL: $name is $got in the manifest, expected $lang" >&2; exit 1; }
    if [ "$name" = hp-deskjet_2300_series ]; then
        gz=$legacy
    else
        gz="$ppds/smudge/$name.ppd.gz"
    fi
    ppd="$tmp/$name.ppd"
    gzip -dc "$gz" > "$ppd"

    run_filter "$ppd" "$tmp/page.txt"
    size=$(wc -c < "$tmp/out.bin" | tr -d ' ')
    [ "$size" -gt 0 ] || { echo "FAIL: $lang ($name): empty output" >&2; exit 1; }
    grep -q 'PAGE: 1 1' "$tmp/hpcups.log" \
        || { echo "FAIL: $lang ($name): filter did not report a page" >&2; exit 1; }
    check_language "$lang" \
        || { echo "FAIL: $lang ($name): expected header bytes not found" >&2; exit 1; }
    case $lang in
    ljzjstream|ljzxstream) check_jbig "$lang" ;;
    esac
    case $lang in
    ljmono|ljcolor|ljfastraster|pcl3gui2|pcl3gui|pcl3)
        has "$UEL" || { echo "FAIL: $lang ($name): no UEL at end of job" >&2; exit 1; } ;;
    esac
    golden_check "$lang" "$name"
    echo "PASS: $lang ($name) produced $size bytes"
    [ "$lang" = pcl3gui2 ] && pcl3gui2_ppd=$ppd
done

if [ -n "${UPDATE_GOLDEN:-}" ]; then
    {
        echo "# SPDX-License-Identifier: AGPL-3.0-or-later"
        echo "# Copyright (C) 2026 Gamunu Balagalla"
        echo "#"
        echo "# language, SHA-256 of the test page raster, SHA-256 of the masked filter output."
        echo "# Written by UPDATE_GOLDEN=1 scripts/test-local.sh. hbpl1 is not listed."
        sort "$tmp/golden/new"
    } > "$golden"
    echo "PASS: golden hashes written to tests/golden/outputs.sha256"
else
    echo "PASS: filter output matches the golden hashes"
fi

# ---- 3. two pages on the DeskJet 2300 ----
i=1
while [ "$i" -le 120 ]; do
    echo "line $i of the two page test"
    i=$((i + 1))
done > "$tmp/two.txt"
run_filter "$pcl3gui2_ppd" "$tmp/two.txt"

pages=$(grep -c '^PAGE: ' "$tmp/hpcups.log")
[ "$pages" -eq 2 ] || { echo "FAIL: two pages expected, filter reported $pages" >&2; exit 1; }
starts "${ESC}E" || { echo "FAIL: two page output does not start with ESC E" >&2; exit 1; }
has "$UEL" || { echo "FAIL: no UEL sequence in two page output" >&2; exit 1; }

echo "PASS: two page job produced $(wc -c < "$tmp/out.bin" | tr -d ' ') bytes, $pages pages"
