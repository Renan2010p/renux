#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Build a hybrid BIOS/UEFI bootable ISO for Renux/amd64.
#
# Following FreeBSD's boot model (Handbook, "The FreeBSD Booting Process"),
# the loader loads only the kernel; the root filesystem is embedded in the
# kernel itself (MD_ROOT), so no modules travel on the medium. Build the
# embedded image first with tools/mkrootfs.sh.
#
# Layout produced inside the ISO:
#   /limine.conf
#   /boot/limine/{limine-bios.sys,limine-bios-cd.bin,limine-uefi-cd.bin}
#   /boot/renux/kernel
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
SYS="$ROOT/sys"

KERNEL="${KERNEL:-$SYS/zig-out/bin/kernel}"
CONF="${CONF:-$ROOT/stand/amd64/conf/limine/limine.conf}"
LIMINE="${LIMINE_DIR:-$ROOT/tools/limine}"
OUT="${OUT:-$SYS/zig-out/renux.iso}"
WORK="${WORK:-$SYS/zig-out/iso}"

if [ ! -x "$LIMINE/limine" ]; then
    "$HERE/get-limine.sh"
fi

[ -f "$KERNEL" ] || {
    echo "mkiso: kernel not built at $KERNEL (run 'zig build buildkernel' first)" >&2
    exit 1
}

command -v xorriso >/dev/null 2>&1 || {
    echo "mkiso: 'xorriso' is required to build the ISO" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/boot/limine" "$WORK/boot/renux" "$WORK/EFI/BOOT"

cp "$LIMINE/limine-bios.sys" "$LIMINE/limine-bios-cd.bin" "$LIMINE/limine-uefi-cd.bin" "$WORK/boot/limine/"
cp "$LIMINE/BOOTX64.EFI" "$WORK/EFI/BOOT/"
cp "$CONF" "$WORK/limine.conf"
cp "$KERNEL" "$WORK/boot/renux/kernel"

xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -hfsplus -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$WORK" -o "$OUT"

"$LIMINE/limine" bios-install "$OUT"

echo "mkiso: $OUT"
