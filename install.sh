#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla
#
# Install the latest Smudge release:
#
#   curl -fsSL https://raw.githubusercontent.com/gamunu/smudge/main/install.sh | sh
#
# Downloads the newest .pkg from GitHub Releases, checks it against the
# release's SHA256SUMS, verifies its build provenance when gh is installed,
# and installs it with Apple's installer command.
# Set HPCUPS_VERSION=0.1.0 to install a specific version.

set -eu

REPO=gamunu/smudge

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"
[ "$(uname -m)" = arm64 ] || die "Smudge is built for Apple Silicon Macs only"

if [ -n "${HPCUPS_VERSION:-}" ]; then
    tag="v${HPCUPS_VERSION#v}"
else
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$tag" ] || die "could not find the latest release"
fi
version=${tag#v}
pkg="smudge-$version.pkg"
base="https://github.com/$REPO/releases/download/$tag"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading $pkg"
curl -fL --progress-bar -o "$tmp/$pkg" "$base/$pkg" || die "download failed"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "could not download SHA256SUMS for $tag"

say "Checking the download"
expected=$(awk -v f="$pkg" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || die "$pkg is not listed in SHA256SUMS"
actual=$(shasum -a 256 "$tmp/$pkg" | awk '{ print $1 }')
[ "$expected" = "$actual" ] || die "checksum mismatch for $pkg"

if command -v gh >/dev/null 2>&1; then
    say "Verifying build provenance"
    gh attestation verify "$tmp/$pkg" --repo "$REPO" >/dev/null || die "build provenance check failed for $pkg"
else
    say "Build provenance not checked (gh is not installed). To check it, install gh and run: gh attestation verify $pkg --repo $REPO"
fi

say "Installing (macOS will ask for your password)"
sudo installer -pkg "$tmp/$pkg" -target / || die "installer failed"

say ""
say "Smudge $version is installed."
say "Next: plug in the printer, open System Settings > Printers & Scanners,"
say "click Add Printer, pick your HP printer, and set Use to the"
say "\"..., Smudge\" driver. Then open Smudge from Applications."
