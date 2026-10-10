#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The ZenBSD Project
#
# Fetch a pinned Limine release and build its host utility. The result lands in
# sys/zig-out/limine/ (build output, git-ignored) and is reused by
# stand/amd64/limine/mkiso.sh.
set -eu

VERSION="12.9.3"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # sys/stand/amd64/limine
SYS="$(CDPATH= cd -- "$HERE/../../.." && pwd)"         # sys/
DEST="${LIMINE_DIR:-$SYS/zig-out/limine}"
URL="https://github.com/Limine-Bootloader/Limine/releases/download/v${VERSION}/limine-binary.tar.xz"

if [ -x "$DEST/limine" ] && [ -f "$DEST/limine-bios.sys" ]; then
    echo "limine: already installed in $DEST"
    exit 0
fi

command -v curl >/dev/null 2>&1 || {
    echo "limine: 'curl' is required to download Limine" >&2
    exit 1
}
command -v cc >/dev/null 2>&1 || {
    echo "limine: a C compiler ('cc') is required to build the host tool" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "limine: downloading v${VERSION} ..."
curl -fsSL -o "$tmp/limine.tar.xz" "$URL"
tar -xf "$tmp/limine.tar.xz" -C "$tmp"

mkdir -p "$DEST"
cp -a "$tmp/limine-binary/." "$DEST/"

echo "limine: building host tool ..."
cc -O2 -o "$DEST/limine" "$DEST/limine.c"

echo "limine: installed to $DEST"
