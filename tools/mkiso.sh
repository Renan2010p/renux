#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Build a hybrid BIOS/UEFI bootable ISO for Renux/amd64.
#
# Legacy: this is the old xorriso + mtools + Limine path. `zig build iso` no
# longer uses it -- tools/mkiso.zig writes a UEFI-only ISO with no external
# tools. Kept for reference and as the BIOS/hybrid fallback.
#
# Usage: mkiso.sh <kernel> <loader.efi> <out.iso>
#
# Following FreeBSD's boot model (Handbook, "The FreeBSD Booting Process"),
# the loader loads only the kernel; the root filesystem is embedded in the
# kernel itself (MD_ROOT), so no modules travel on the medium.
#
#   UEFI  the Renux loader (stand/efi/loader), from an El Torito FAT image
#         holding \EFI\BOOT\BOOTX64.EFI, /boot/kernel/kernel and
#         /boot/defaults/loader.conf (UEFI firmware reads FAT, not ISO 9660)
#   BIOS  Limine, from the ISO 9660 tree
#
# Layout produced inside the ISO:
#   /limine.conf
#   /boot/limine/{limine-bios.sys,limine-bios-cd.bin}
#   /boot/kernel/kernel
#   /boot/defaults/loader.conf
#   /boot/efi.img
set -eu

[ $# -eq 3 ] || {
    echo "usage: mkiso.sh <kernel> <loader.efi> <out.iso>" >&2
    exit 2
}
KERNEL="$1"
LOADER="$2"
OUT="$3"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
DEFAULTS="${DEFAULTS:-$ROOT/stand/defaults/loader.conf}"
CONF="${CONF:-$ROOT/stand/amd64/conf/limine/limine.conf}"
LIMINE="${LIMINE_DIR:-$ROOT/tools/limine}"
WORK="${WORK:-$(dirname -- "$OUT")/iso}"

if [ ! -x "$LIMINE/limine" ]; then
    "$HERE/get-limine.sh"
fi

[ -f "$KERNEL" ] && [ -f "$LOADER" ] || {
    echo "mkiso: no kernel at $KERNEL or no loader at $LOADER" >&2
    exit 1
}

for tool in xorriso mkfs.fat mmd mcopy; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "mkiso: '$tool' is required to build the ISO" >&2
        exit 1
    }
done

rm -rf "$WORK"
mkdir -p "$WORK/boot/limine" "$WORK/boot/kernel" "$WORK/boot/defaults"

cp "$LIMINE/limine-bios.sys" "$LIMINE/limine-bios-cd.bin" "$WORK/boot/limine/"
cp "$CONF" "$WORK/limine.conf"
cp "$KERNEL" "$WORK/boot/kernel/kernel"
cp "$DEFAULTS" "$WORK/boot/defaults/loader.conf"

# The UEFI boot image: a FAT filesystem sized for the loader and the kernel.
EFIIMG="$WORK/boot/efi.img"
kb=$(( ( $(wc -c < "$KERNEL") + $(wc -c < "$LOADER") ) / 1024 + 4096 ))
mkfs.fat -C -n RENUXEFI "$EFIIMG" "$kb" >/dev/null
mmd -i "$EFIIMG" ::/EFI ::/EFI/BOOT ::/boot ::/boot/kernel ::/boot/defaults
mcopy -i "$EFIIMG" "$LOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$EFIIMG" "$KERNEL" ::/boot/kernel/kernel
mcopy -i "$EFIIMG" "$DEFAULTS" ::/boot/defaults/loader.conf

# The tools are chatty; their output is only shown when one of them fails.
LOG="$WORK.log"
if ! { xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -hfsplus -apm-block-size 2048 \
    --efi-boot boot/efi.img \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$WORK" -o "$OUT" &&
    "$LIMINE/limine" bios-install "$OUT"; } >"$LOG" 2>&1; then
    cat "$LOG" >&2
    echo "mkiso: building $OUT failed" >&2
    exit 1
fi
rm -f "$LOG"
