#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Build the root filesystem image that is embedded in the kernel (FreeBSD's
# MD_ROOT): stage the userland into a tree, pack it into an ext2 image, and
# leave it at sys/root.img so sys/fs/rootimage.zig can @embedFile() it.
#
# The image is only replaced when its bytes actually change, so the kernel is
# not rebuilt when nothing changed.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
SYS="$ROOT/sys"

OUT="${OUT:-$SYS/root.img}"
WORK="${WORK:-$SYS/zig-out/rootfs}"
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
FBSDLIB="${FBSDLIB:-}"

# Build whatever is missing.
[ -f "$INIT" ] || ( cd "$ROOT/sbin" && zig build )
[ -f "$GETTY" ] || ( cd "$ROOT/libexec" && zig build )
[ -f "$SH" ] || ( cd "$ROOT/bin" && zig build )
[ -f "$LOGIN" ] || ( cd "$ROOT/usr.bin" && zig build )
[ -f "$RTLD_SO" ] && [ -f "$LIBC_SO" ] && [ -f "$DYNH" ] || "$ROOT/tools/build-dyn.sh" >/dev/null

command -v mke2fs >/dev/null 2>&1 || {
    echo "mkrootfs: 'mke2fs' is required" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/boot" \
    "$WORK/sbin" "$WORK/bin" "$WORK/usr/bin" "$WORK/usr/sbin" "$WORK/usr/libexec" \
    "$WORK/etc" "$WORK/etc/rc.d" "$WORK/lib" "$WORK/libexec" \
    "$WORK/dev" "$WORK/tmp" "$WORK/var" "$WORK/var/log" "$WORK/var/run"

cp -a "$INIT" "$WORK/sbin/init"
cp -a "$GETTY" "$WORK/usr/libexec/getty"
cp -a "$LOGIN" "$WORK/usr/bin/login"
cp -a "$STAT" "$WORK/usr/bin/stat"
cp -a "$SH" "$WORK/bin/sh"
# The native shell stays available as /bin/renux-sh; when a FreeBSD userland is
# present it replaces /bin/sh (the default login shell).
cp -a "$SH" "$WORK/bin/renux-sh"
cp -a "$LS" "$WORK/bin/ls"
cp -a "$CAT" "$WORK/bin/cat"
cp -a "$ECHO" "$WORK/bin/echo"
cp -a "$PWDCMD" "$WORK/bin/pwd"
cp -a "$MKDIR" "$WORK/bin/mkdir"
cp -a "$RM" "$WORK/bin/rm"
cp -a "$RMDIR" "$WORK/bin/rmdir"
cp -a "$HELLO" "$WORK/bin/hello"
cp -a "$WC" "$WORK/bin/wc"
cp -a "$TUI" "$WORK/bin/tui"
cp -a "$NANO" "$WORK/bin/nano"
cp -a "$NANO" "$WORK/bin/edit"
cp -a "$DMESG" "$WORK/bin/dmesg"
cp -a "$LOGGER" "$WORK/usr/bin/logger"
cp -a "$SYSLOGD" "$WORK/usr/sbin/syslogd"
cp -a "$RC" "$WORK/etc/rc"
cp -a "$ROOT/etc/rc.d/syslogd" "$WORK/etc/rc.d/syslogd"
cp -a "$RTLD_SO" "$WORK/libexec/ld-elf.so.1"
cp -a "$LIBC_SO" "$WORK/lib/libc.so.1"
cp -a "$DYNH" "$WORK/bin/dynhello"

# A FreeBSD userland subset (optional): the real libc.so.7 and dynamic programs
# (nano, htop, sh), so FreeBSD binaries can run through ld-elf.so.1.
if [ -n "$FBSDLIB" ] && [ -d "$FBSDLIB" ]; then
    if [ -f "$FBSDLIB/libexec/ld-elf.so.1" ]; then
        cp -a "$FBSDLIB/libexec/ld-elf.so.1" "$WORK/libexec/ld-elf.so.1"
    fi
    for f in "$FBSDLIB"/lib/*; do
        [ -f "$f" ] || continue
        cp -a "$f" "$WORK/lib/$(basename "$f")"
    done
    mkdir -p "$WORK/usr/local/bin"
    [ -f "$FBSDLIB/usr/local/bin/nano" ] && cp -a "$FBSDLIB/usr/local/bin/nano" "$WORK/usr/local/bin/nano"
    [ -f "$FBSDLIB/usr/local/bin/htop" ] && cp -a "$FBSDLIB/usr/local/bin/htop" "$WORK/usr/local/bin/htop"
    if [ -f "$FBSDLIB/usr/share/misc/termcap" ]; then
        mkdir -p "$WORK/usr/share/misc"
        cp -a "$FBSDLIB/usr/share/misc/termcap" "$WORK/usr/share/misc/termcap"
    fi
    # terminfo entries, for ncurses/libedit (compiled on the build host).
    for t in x/xterm x/xterm-256color v/vt100 v/vt220 l/linux c/cons25 n/network; do
        if [ -f "/usr/share/terminfo/$t" ]; then
            mkdir -p "$WORK/usr/share/terminfo/$(dirname "$t")"
            cp -a "/usr/share/terminfo/$t" "$WORK/usr/share/terminfo/$t"
        fi
    done
    [ -f "$FBSDLIB/sbin/init" ] && cp -a "$FBSDLIB/sbin/init" "$WORK/sbin/init"
    [ -f "$FBSDLIB/etc/ttys" ] && cp -a "$FBSDLIB/etc/ttys" "$WORK/etc/ttys"
    if [ -f "$FBSDLIB/bin/echo" ]; then
        cp -a "$FBSDLIB/bin/echo" "$WORK/usr/bin/fbsd-echo"
    fi
    if [ -f "$FBSDLIB/bin/sh" ]; then
        # FreeBSD's sh becomes the default /bin/sh (the login shell).
        cp -a "$FBSDLIB/bin/sh" "$WORK/bin/sh"
        cp -a "$FBSDLIB/bin/sh" "$WORK/bin/fbsdsh"
    fi
fi

# Pack the tree into an ext2 image. A fixed UUID and a fake time keep the image
# byte-for-byte reproducible so an unchanged userland does not force a kernel
# rebuild.
find "$WORK" -exec touch -h -d @1000000000 {} + 2>/dev/null || true
used_kb="$(du -sk "$WORK" | awk '{print $1}')"
blocks=$((used_kb + used_kb / 2 + 8192))
tmp="$WORK.img"
rm -f "$tmp"
E2FSPROGS_FAKE_TIME=1000000000 mke2fs -q -t ext2 -b 1024 -I 128 -m 0 -i 4096 \
    -O ^resize_inode,^dir_index -U 00000000-0000-0000-0000-000000000000 \
    -d "$WORK" "$tmp" "$blocks" || {
    echo "mkrootfs: mke2fs failed" >&2
    exit 1
}

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    rm -f "$tmp"
    echo "mkrootfs: $OUT unchanged"
else
    mv -f "$tmp" "$OUT"
    echo "mkrootfs: $OUT ($(wc -c < "$OUT") bytes)"
fi
