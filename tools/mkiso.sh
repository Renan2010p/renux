#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 The Renux Project
#
# Build a hybrid BIOS/UEFI bootable ISO for Renux/amd64.
#
# Layout produced inside the ISO (paths as mounted at runtime):
#   /limine.conf
#   /boot/limine/{limine-bios.sys,limine-bios-cd.bin,limine-uefi-cd.bin}
#   /boot/renux/kernel
#   /sbin/init
#   /libexec/getty           (installed as /usr/libexec/getty)
#   /usr/bin/login
#   /usr/bin/stat
#   /bin/sh /bin/ls /bin/cat
#   /etc/rc
#   /EFI/BOOT/BOOTX64.EFI
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
SYS="$ROOT/sys"

KERNEL="${KERNEL:-$SYS/zig-out/bin/kernel}"
CONF="${CONF:-$ROOT/stand/amd64/conf/limine/limine.conf}"
LIMINE="${LIMINE_DIR:-$ROOT/tools/limine}"
OUT="${OUT:-$SYS/zig-out/renux.iso}"
WORK="${WORK:-$SYS/zig-out/iso}"
INIT="${INIT:-$ROOT/sbin/zig-out/bin/init}"
GETTY="${GETTY:-$ROOT/libexec/zig-out/bin/getty}"
LOGIN="${LOGIN:-$ROOT/usr.bin/zig-out/bin/login}"
STAT="${STAT:-$ROOT/usr.bin/zig-out/bin/stat}"
SH="${SH:-$ROOT/bin/zig-out/bin/sh}"
LS="${LS:-$ROOT/bin/zig-out/bin/ls}"
CAT="${CAT:-$ROOT/bin/zig-out/bin/cat}"
ECHO="${ECHO:-$ROOT/bin/zig-out/bin/echo}"
PWDCMD="${PWDCMD:-$ROOT/bin/zig-out/bin/pwd}"
MKDIR="${MKDIR:-$ROOT/bin/zig-out/bin/mkdir}"
RM="${RM:-$ROOT/bin/zig-out/bin/rm}"
RMDIR="${RMDIR:-$ROOT/bin/zig-out/bin/rmdir}"
HELLO="${HELLO:-$ROOT/bin/zig-out/bin/hello}"
WC="${WC:-$ROOT/bin/zig-out/bin/wc}"
TUI="${TUI:-$ROOT/bin/zig-out/bin/tui}"
NANO="${NANO:-$ROOT/bin/zig-out/bin/nano}"
DMESG="${DMESG:-$ROOT/bin/zig-out/bin/dmesg}"
LOGGER="${LOGGER:-$ROOT/bin/zig-out/bin/logger}"
SYSLOGD="${SYSLOGD:-$ROOT/bin/zig-out/bin/syslogd}"
RTLD_SO="${RTLD_SO:-$ROOT/libexec/rtld-elf/zig-out/ld-elf.so.1}"
LIBC_SO="${LIBC_SO:-$ROOT/lib/zig-out/libc.so.1}"
DYNH="${DYNH:-$ROOT/examples/dynhello/zig-out/dynhello}"
RC="${RC:-$ROOT/etc/rc}"

if [ ! -x "$LIMINE/limine" ]; then
    "$HERE/get-limine.sh"
fi

[ -f "$KERNEL" ] || {
    echo "mkiso: kernel not built at $KERNEL (run 'zig build buildkernel' first)" >&2
    exit 1
}

# Build the userland if it is not present yet.
[ -f "$INIT" ] || ( cd "$ROOT/sbin" && zig build )
[ -f "$GETTY" ] || ( cd "$ROOT/libexec" && zig build )
[ -f "$SH" ] || ( cd "$ROOT/bin" && zig build )
[ -f "$LOGIN" ] || ( cd "$ROOT/usr.bin" && zig build )
# Build the dynamic linking pieces if they are missing.
[ -f "$RTLD_SO" ] && [ -f "$LIBC_SO" ] && [ -f "$DYNH" ] || "$ROOT/tools/build-dyn.sh" >/dev/null

command -v xorriso >/dev/null 2>&1 || {
    echo "mkiso: 'xorriso' is required to build the ISO" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/boot/limine" "$WORK/boot/renux" "$WORK/EFI/BOOT" \
    "$WORK/sbin" "$WORK/bin" "$WORK/usr/bin" "$WORK/usr/sbin" "$WORK/usr/libexec" \
    "$WORK/etc" "$WORK/etc/rc.d" "$WORK/lib" "$WORK/libexec"

cp "$LIMINE/limine-bios.sys" "$LIMINE/limine-bios-cd.bin" "$LIMINE/limine-uefi-cd.bin" "$WORK/boot/limine/"
cp "$LIMINE/BOOTX64.EFI" "$WORK/EFI/BOOT/"
cp "$CONF" "$WORK/limine.conf"
cp "$KERNEL" "$WORK/boot/renux/kernel"
cp "$INIT" "$WORK/sbin/init"
cp "$GETTY" "$WORK/usr/libexec/getty"
cp "$LOGIN" "$WORK/usr/bin/login"
cp "$STAT" "$WORK/usr/bin/stat"
cp "$SH" "$WORK/bin/sh"
cp "$LS" "$WORK/bin/ls"
cp "$CAT" "$WORK/bin/cat"
cp "$ECHO" "$WORK/bin/echo"
cp "$PWDCMD" "$WORK/bin/pwd"
cp "$MKDIR" "$WORK/bin/mkdir"
cp "$RM" "$WORK/bin/rm"
cp "$RMDIR" "$WORK/bin/rmdir"
cp "$HELLO" "$WORK/bin/hello"
cp "$WC" "$WORK/bin/wc"
cp "$TUI" "$WORK/bin/tui"
cp "$NANO" "$WORK/bin/nano"
cp "$NANO" "$WORK/bin/edit"
cp "$DMESG" "$WORK/bin/dmesg"
cp "$LOGGER" "$WORK/usr/bin/logger"
cp "$SYSLOGD" "$WORK/usr/sbin/syslogd"
cp "$RC" "$WORK/etc/rc"
cp "$ROOT/etc/rc.d/syslogd" "$WORK/etc/rc.d/syslogd"
cp "$RTLD_SO" "$WORK/libexec/ld-elf.so.1"
cp "$LIBC_SO" "$WORK/lib/libc.so.1"
cp "$DYNH" "$WORK/bin/dynhello"

xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -hfsplus -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$WORK" -o "$OUT"

"$LIMINE/limine" bios-install "$OUT"

echo "mkiso: $OUT"
