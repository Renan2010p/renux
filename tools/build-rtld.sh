#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The Renux Project
#
# Compile FreeBSD's rtld-elf (the dynamic linker) for Renux.
#
# The sources are vendored from FreeBSD under libexec/rtld-elf, together with a
# small FreeBSD-compatible header tree (libexec/rtld-elf/include). The C files,
# rtld_syscalls.c (the __sys_* layer) and the amd64 start assembly compile and
# link into ld-elf.so.1.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
RTLD="$ROOT/libexec/rtld-elf"
OUT="${OUT:-$RTLD/zig-out}"

CC="${CC:-zig cc --target=x86_64-freestanding-none}"
inc="-I $RTLD/include -I $RTLD -I $RTLD/amd64 -I $RTLD/rtld-libc \
	-include sys/cdefs.h -include sys/types.h -include unistd.h"

mkdir -p "$OUT/pic"

objs=""
for f in rtld.c map_object.c rtld_malloc.c rtld_printf.c xmalloc.c debug.c \
	libmap.c rtld_lock.c amd64/reloc.c rtld-libc/rtld_libc.c rtld_syscalls.c; do
	o="$OUT/pic/$(basename "$f").o"
	$CC -DIN_RTLD -fPIC -fno-sanitize=undefined -c "$RTLD/$f" $inc -o "$o"
	objs="$objs $o"
done

$CC -DIN_RTLD -fPIC -c "$RTLD/amd64/rtld_start.S" \
	-I "$RTLD/include" -I "$RTLD" -I "$RTLD/amd64" -o "$OUT/pic/rtld_start.o"
objs="$objs $OUT/pic/rtld_start.o"

# Link ld-elf.so.1 as a shared object. The entry point is .rtld_start (the
# leading dot is FreeBSD's). zig cc refuses -shared on a freestanding target, so
# the bundled lld is invoked directly.
ld="${LD:-zig ld.lld}"
$ld -shared -e .rtld_start -Bsymbolic --strip-debug \
	-o "$OUT/ld-elf.so.1" $objs

echo "built $OUT/ld-elf.so.1"
readelf -h "$OUT/ld-elf.so.1" | grep -E "Type|Entry"
