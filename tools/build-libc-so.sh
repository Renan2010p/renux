#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The Renux Project
#
# Build the shared C library (libc.so.1) for dynamically linked programs.
#
# The C ABI wrappers (lib/libc/c.zig) compile as a position-independent object,
# which lld links into a shared object. rtld-elf (ld-elf.so.1) resolves the
# program's symbols against this library at run time.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
OUT="${OUT:-$ROOT/lib/zig-out}"

mkdir -p "$OUT"

zig build-obj -fPIC -OReleaseSmall -target x86_64-freestanding-none \
    "$ROOT/lib/libc/c.zig" -femit-bin="$OUT/libc.o"

zig ld.lld -shared -soname libc.so.1 --strip-debug \
    -o "$OUT/libc.so.1" "$OUT/libc.o"

echo "built $OUT/libc.so.1"
readelf -h "$OUT/libc.so.1" | grep -E "Type|Entry"
