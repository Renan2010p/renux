#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The Renux Project
#
# Build everything for a dynamically linked program on Renux: the shared libc,
# the interpreter (ld-elf.so.1) and a hello that links against them.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
OUT="${OUT:-$ROOT/examples/dynhello/zig-out}"

"$HERE/build-libc-so.sh"
"$HERE/build-rtld.sh"
ln -sf libc.so.1 "$ROOT/lib/zig-out/libc.so"

mkdir -p "$OUT"
CC="zig cc --target=x86_64-freestanding-none -fPIC -fno-sanitize=undefined \
	-I $ROOT/lib/include"

$CC -c "$ROOT/examples/dynhello/hello.c" -o "$OUT/hello.o"
$CC -c "$ROOT/examples/dynhello/crt.c" -o "$OUT/crt.o"

zig ld.lld --dynamic-linker /libexec/ld-elf.so.1 -e _start \
	-o "$OUT/dynhello" "$OUT/crt.o" "$OUT/hello.o" \
	-L "$ROOT/lib/zig-out" -lc

echo "built $OUT/dynhello"
readelf -h "$OUT/dynhello" | grep -E "Type|Entry"
readelf -d "$OUT/dynhello" | grep -i NEEDED
