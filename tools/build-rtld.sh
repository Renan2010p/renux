#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The Renux Project
#
# Compile FreeBSD's rtld-elf (the dynamic linker) for Renux.
#
# The sources are vendored from FreeBSD under libexec/rtld-elf, together with a
# small FreeBSD-compatible header tree (libexec/rtld-elf/include). All of the C
# files and the amd64 start assembly compile; linking ld-elf.so.1 still needs a
# syscall layer for the __sys_* wrappers in rtld-libc/rtld_libc.c, so this
# script stops at producing the objects.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
RTLD="$ROOT/libexec/rtld-elf"
OUT="${OUT:-$RTLD/zig-out}"

CC="${CC:-zig cc --target=x86_64-freestanding-none}"
INC="-I $RTLD/include -I $RTLD -I $RTLD/amd64 -I $RTLD/rtld-libc \
	-include sys/cdefs.h -include sys/types.h -include unistd.h"

mkdir -p "$OUT"

objs=""
for f in rtld.c map_object.c rtld_malloc.c rtld_printf.c xmalloc.c debug.c \
	libmap.c rtld_lock.c amd64/reloc.c rtld-libc/rtld_libc.c; do
	o="$OUT/$(basename "$f").o"
	$CC -DIN_RTLD -c "$RTLD/$f" $INC -o "$o"
	objs="$objs $o"
done

$CC -DIN_RTLD -c "$RTLD/amd64/rtld_start.S" \
	-I "$RTLD/include" -I "$RTLD" -I "$RTLD/amd64" -o "$OUT/rtld_start.o"
objs="$objs $OUT/rtld_start.o"

echo "rtld-elf objects in $OUT:"
echo "$objs"
