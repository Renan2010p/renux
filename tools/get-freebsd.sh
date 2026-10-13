#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Fetch the FreeBSD base system Renux runs as its userland.
#
# Renux speaks the FreeBSD/amd64 ABI, so it runs FreeBSD's own programs
# (login, getty, sh, the base utilities) unchanged. This downloads the base
# set of the FreeBSD release whose osreldate the kernel reports
# (sys/kern/kern_sysctl.zig), checks it against a pinned SHA-256 and unpacks
# it into tools/freebsd/root. Nothing here is committed; tools/mkrootfs.sh
# copies the parts the root image needs (FBSDLIB=tools/freebsd/root).
#
# FreeBSD is distributed under the BSD licence; its notices travel with the
# files (see /COPYRIGHT in the unpacked tree).
set -eu

RELEASE="14.5-RELEASE"
SHA256="d16b68fe0e9e136ce67ab1084042c848bbffecd1eb295f206bd1c6785deb45a4"
URL="https://download.freebsd.org/releases/amd64/$RELEASE/base.txz"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEST="${FREEBSD_DIR:-$HERE/freebsd}"
TXZ="$DEST/base-$RELEASE.txz"
ROOT="$DEST/root"

if [ -f "$ROOT/.release" ] && [ "$(cat "$ROOT/.release")" = "$RELEASE" ]; then
    echo "get-freebsd: $RELEASE already unpacked in $ROOT"
    exit 0
fi

mkdir -p "$DEST"
if [ ! -f "$TXZ" ]; then
    echo "get-freebsd: downloading $URL"
    curl -fL --progress-bar -o "$TXZ.part" "$URL"
    mv "$TXZ.part" "$TXZ"
fi

echo "$SHA256  $TXZ" | sha256sum -c - >/dev/null || {
    echo "get-freebsd: checksum mismatch for $TXZ" >&2
    rm -f "$TXZ"
    exit 1
}

echo "get-freebsd: unpacking into $ROOT"
rm -rf "$ROOT"
mkdir -p "$ROOT"
# Debug info, tests, headers, 32-bit compat and documentation are not needed
# to run the system.
tar -xJf "$TXZ" -C "$ROOT" \
    --exclude './usr/lib/debug' --exclude './usr/tests' \
    --exclude './usr/include' --exclude './usr/lib32' \
    --exclude './usr/share/doc' --exclude './usr/share/man' \
    --exclude './usr/share/examples' --exclude './usr/share/i18n' \
    --exclude './usr/share/locale' --exclude './rescue' \
    --exclude './boot' 2>/dev/null || true
echo "$RELEASE" > "$ROOT/.release"
echo "get-freebsd: $RELEASE ready in $ROOT"
