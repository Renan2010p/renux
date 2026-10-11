#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Assemble the C cross-compilation sysroot: the headers, the static C library
# and the userland linker script, ready for tools/zcc.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root

LIB="$ROOT/lib"
OUT="${OUT:-$LIB/zig-out/sysroot}"
ARCHIVE="$LIB/zig-out/lib/libc.a"

if [ ! -f "$ARCHIVE" ]; then
    ( cd "$LIB" && zig build )
fi

rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib"
cp -R "$LIB/include/." "$OUT/include/"
cp "$ARCHIVE" "$OUT/lib/libc.a"
cp "$LIB/libc/libc.ldscript" "$OUT/lib/renux.ldscript"

echo "sysroot: $OUT"
