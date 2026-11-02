#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Per-module line coverage for the Swift app, from the last
#   cd app && swift test --enable-code-coverage
# run. Prints a table, appends it to $GITHUB_STEP_SUMMARY when set, and fails
# when a module is below its floor in scripts/coverage-floor.txt
# ("Module percent" per line).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
floor_file="$root/scripts/coverage-floor.txt"
sources="$root/app/Sources"

codecov=$(cd "$root/app" && swift test --show-codecov-path 2>/dev/null | tail -n 1)
[ -f "$codecov" ] || { echo "no coverage data at $codecov, run swift test --enable-code-coverage first" >&2; exit 1; }

# SwiftPM's JSON only covers the sources linked into one test bundle. Export from
# every bundle so a module is counted when any of them runs it.
cov_dir=$(dirname "$codecov")
profdata="$cov_dir/default.profdata"
products=$(dirname "$cov_dir")
[ -f "$profdata" ] || { echo "no $profdata, run swift test --enable-code-coverage first" >&2; exit 1; }
bins=()
for bundle in "$products"/*.xctest; do
    bins+=("$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
merged=$(mktemp)
trap 'rm -f "$merged"' EXIT
objects=()
for b in "${bins[@]:1}"; do objects+=(-object "$b"); done
xcrun llvm-cov export -instr-profile "$profdata" "${bins[0]}" ${objects[@]+"${objects[@]}"} > "$merged"

python3 -I - "$merged" "$sources" "$floor_file" <<'PY'
import json
import os
import sys

codecov, sources, floor_file = sys.argv[1:4]
modules = ["SmudgeKit", "SmudgeScan", "SmudgeCore", "Smudge", "smudge-scand"]

covered = {m: 0 for m in modules}
count = {m: 0 for m in modules}
with open(codecov, encoding="utf-8") as f:
    data = json.load(f)
for unit in data.get("data", []):
    for entry in unit.get("files", []):
        rel = os.path.relpath(entry["filename"], sources)
        parts = rel.split(os.sep)
        if parts[0] == ".." or ".build" in parts or parts[0] not in count:
            continue
        lines = entry["summary"]["lines"]
        covered[parts[0]] += lines["covered"]
        count[parts[0]] += lines["count"]

floors = {}
with open(floor_file, encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        name, pct = line.split()
        if name not in count:
            sys.exit(f"error: {floor_file} names unknown module {name}")
        floors[name] = float(pct)

rows = ["| Module | Covered | Lines | Line coverage | Floor | Status |",
        "| --- | ---: | ---: | ---: | ---: | --- |"]
failed = []
for m in modules:
    floor = floors.get(m)
    floor_text = f"{floor:g}%" if floor is not None else "-"
    if count[m] == 0:
        # The test binaries link no instrumented source for this module.
        pct_text = "n/a"
        status = "no data"
        if floor is not None:
            status = "no data, below floor"
            failed.append(f"{m} has no coverage data, floor is {floor:g}%")
        rows.append(f"| {m} | 0 | 0 | {pct_text} | {floor_text} | {status} |")
        continue
    pct = 100.0 * covered[m] / count[m]
    if floor is None:
        status = "no floor"
    elif pct < floor:
        status = "below floor"
        failed.append(f"{m} {pct:.1f}% is below the floor of {floor:g}%")
    else:
        status = "ok"
    rows.append(f"| {m} | {covered[m]} | {count[m]} | {pct:.1f}% | {floor_text} | {status} |")

table = "\n".join(rows)
print(table)

summary = os.environ.get("GITHUB_STEP_SUMMARY", "")
if summary:
    with open(summary, "a", encoding="utf-8") as f:
        f.write("## Swift line coverage\n\n" + table + "\n")

for message in failed:
    print(f"error: {message}", file=sys.stderr)
sys.exit(1 if failed else 0)
PY
