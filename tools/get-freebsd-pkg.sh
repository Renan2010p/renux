#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Fetch FreeBSD packages (bash, nano, ...) for the Renux root image.
#
# Superseded by `zig build fetch` (tools/fetch.zig), which does the same with
# only Zig -- including the catalog's RSA signature -- with no curl, tar, xz,
# sha256sum or openssl. Kept for reference.
#
# Renux runs FreeBSD/amd64 binaries, so it can use FreeBSD's packages as they
# are. pkg(8) does not run on the build host, so this script does what it
# does, with the same chain of trust:
#
#   1. download the repository catalog (packagesite.pkg);
#   2. check that the catalog's signing key matches a fingerprint FreeBSD
#      trusts (/usr/share/keys/pkg/trusted in the base system, itself checked
#      against a pinned SHA-256 by tools/get-freebsd.sh);
#   3. verify the catalog's signature with that key (RSA over the SHA-256 of
#      packagesite.yaml, as pkg signs it);
#   4. resolve the requested packages and their dependencies;
#   5. download each one and compare its checksum with the catalog's;
#   6. unpack them into tools/freebsd/pkgroot, which tools/mkrootfs.sh uses.
#
# Usage: tools/get-freebsd-pkg.sh [package ...]   (default: bash nano)
# Nothing here is committed (tools/freebsd is ignored by git).
set -eu

ABI="FreeBSD:14:amd64"
REPO="https://pkg.freebsd.org/$ABI/quarterly"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FREEBSD="${FREEBSD_DIR:-$HERE/freebsd}"
BASE="$FREEBSD/root"
DEST="$FREEBSD/pkg"
ROOTDIR="$FREEBSD/pkgroot"
PKGTOOL="$HERE/pkgtool/pkgtool"
TRUSTED="$BASE/usr/share/keys/pkg/trusted"

[ "$#" -gt 0 ] || set -- bash nano

for tool in curl openssl sha256sum zig; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "get-freebsd-pkg: '$tool' is required" >&2
        exit 1
    }
done
[ -d "$TRUSTED" ] || "$HERE/get-freebsd.sh"
if [ ! -x "$PKGTOOL" ] || [ "$HERE/pkgtool/main.zig" -nt "$PKGTOOL" ]; then
    (cd "$HERE/pkgtool" && zig build-exe main.zig --name pkgtool -O ReleaseSafe)
fi

mkdir -p "$DEST/cache"
echo "get-freebsd-pkg: fetching the $ABI catalog"
curl -fsSL -o "$DEST/packagesite.pkg" "$REPO/packagesite.pkg"
rm -rf "$DEST/catalog"
"$PKGTOOL" extract "$DEST/packagesite.pkg" "$DEST/catalog"
CAT="$DEST/catalog/packagesite.yaml"

# 2. The signing key must be one FreeBSD trusts.
fp="$(sha256sum "$CAT.pub" | cut -d' ' -f1)"
grep -qs "fingerprint: \"$fp\"" "$TRUSTED"/* || {
    echo "get-freebsd-pkg: the catalog's signing key ($fp) is not trusted" >&2
    exit 1
}

# 3. The signature covers the hexadecimal SHA-256 of the catalog.
sha256sum "$CAT" | cut -d' ' -f1 | tr -d '\n' > "$DEST/catalog.digest"
openssl dgst -sha256 -verify "$CAT.pub" -signature "$CAT.sig" "$DEST/catalog.digest" >/dev/null || {
    echo "get-freebsd-pkg: the catalog signature does not verify" >&2
    exit 1
}
echo "get-freebsd-pkg: catalog signature verified (key $fp)"

# 4-6. Resolve, download, check and unpack.
"$PKGTOOL" resolve "$CAT" "$@" | while read -r path sum name; do
    file="$DEST/cache/$name.pkg"
    if [ ! -f "$file" ] || [ "$("$PKGTOOL" sum "$file")" != "$sum" ]; then
        echo "get-freebsd-pkg: downloading $name"
        curl -fsSL -o "$file.part" "$REPO/$path"
        mv "$file.part" "$file"
    fi
    [ "$("$PKGTOOL" sum "$file")" = "$sum" ] || {
        echo "get-freebsd-pkg: checksum mismatch for $name" >&2
        rm -f "$file"
        exit 1
    }
    "$PKGTOOL" extract "$file" "$ROOTDIR"
    echo "get-freebsd-pkg: $name verified and unpacked"
done
rm -f "$ROOTDIR/+MANIFEST" "$ROOTDIR/+COMPACT_MANIFEST"
echo "get-freebsd-pkg: packages ready in $ROOTDIR"
