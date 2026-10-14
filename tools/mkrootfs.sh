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
FBDRAW="${FBDRAW:-$ROOT/bin/zig-out/bin/fbdraw}"
TUI="${TUI:-$ROOT/bin/zig-out/bin/tui}"
NANO="${NANO:-$ROOT/bin/zig-out/bin/nano}"
DMESG="${DMESG:-$ROOT/bin/zig-out/bin/dmesg}"
LOGGER="${LOGGER:-$ROOT/bin/zig-out/bin/logger}"
SYSLOGD="${SYSLOGD:-$ROOT/bin/zig-out/bin/syslogd}"
RTLD_SO="${RTLD_SO:-$ROOT/libexec/rtld-elf/zig-out/ld-elf.so.1}"
LIBC_SO="${LIBC_SO:-$ROOT/lib/zig-out/libc.so.1}"
DYNH="${DYNH:-$ROOT/examples/dynhello/zig-out/dynhello}"
RC="${RC:-$ROOT/etc/rc}"
# The FreeBSD base system (tools/get-freebsd.sh); used when it is present.
FBSDLIB="${FBSDLIB:-$ROOT/tools/freebsd/root}"
# FreeBSD packages (tools/get-freebsd-pkg.sh: bash, nano); used when present.
PKGROOT="${PKGROOT:-$ROOT/tools/freebsd/pkgroot}"

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
cp -a "$FBDRAW" "$WORK/bin/fbdraw"
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

# The FreeBSD userland. Renux runs FreeBSD's own programs (FreeBSD/amd64 ABI),
# so when the base system is present (tools/get-freebsd.sh) the console login
# is FreeBSD's: getty(8), login(1) with PAM, and sh(1), plus the everyday base
# utilities. Shared libraries are found from each program's DT_NEEDED entries,
# so only what is actually used goes into the image.
if [ -n "$FBSDLIB" ] && [ -d "$FBSDLIB" ]; then
    command -v readelf >/dev/null 2>&1 || {
        echo "mkrootfs: 'readelf' is required for the FreeBSD userland" >&2
        exit 1
    }

    # Programs, by their path in the FreeBSD tree.
    FBSD_PROGS="
        usr/libexec/getty usr/bin/login
        bin/sh bin/ls bin/cat bin/echo bin/pwd bin/mkdir bin/rm bin/rmdir
        bin/cp bin/mv bin/ln bin/chmod bin/date bin/hostname bin/sleep
        bin/test bin/expr bin/kill bin/stty bin/realpath
        usr/bin/uname usr/bin/id usr/bin/whoami usr/bin/env usr/bin/wc
        usr/bin/head usr/bin/tail usr/bin/grep usr/bin/sed usr/bin/awk
        usr/bin/more usr/bin/less usr/bin/vi usr/bin/clear usr/bin/tput
        usr/bin/touch usr/bin/find usr/bin/sort usr/bin/uniq usr/bin/tr
        usr/bin/cut usr/bin/basename usr/bin/dirname usr/bin/true
        usr/bin/false usr/bin/yes usr/bin/printf usr/bin/which
        usr/bin/stat usr/bin/du usr/bin/tee usr/bin/xargs usr/bin/logname
        usr/bin/tty usr/bin/uptime usr/bin/w usr/bin/who usr/bin/hexdump
        usr/bin/fortune usr/bin/resizewin usr/bin/ee
        usr/sbin/pwd_mkdb sbin/ldconfig
    "
    # Programs from FreeBSD packages, when they have been fetched.
    FBSD_PKG_PROGS="usr/local/bin/bash usr/local/bin/nano"
    # PAM modules the login service stack loads (etc/pam.d/login, system).
    FBSD_PAM="pam_self pam_unix pam_securetty pam_nologin pam_login_access
        pam_lastlog pam_xdg pam_permit pam_deny"

    # Locate a library by soname in the FreeBSD library directories.
    fbsd_findlib() {
        for d in lib usr/lib usr/local/lib; do
            if [ -e "$FBSDLIB/$d/$1" ] || [ -e "$PKGROOT/$d/$1" ]; then
                echo "$d/$1"
                return 0
            fi
        done
        return 1
    }

    # Where a FreeBSD file comes from: the base system, else the packages.
    fbsd_src() {
        if [ -e "$FBSDLIB/$1" ]; then
            echo "$FBSDLIB/$1"
        else
            echo "$PKGROOT/$1"
        fi
    }

    # Install one file (and, for an ELF object, its libraries, recursively).
    fbsd_install() {
        rel="$1"
        grep -qx "$rel" "$WORK/.fbsd-$$" && return 0
        src="$(fbsd_src "$rel")"
        [ -e "$src" ] || {
            echo "mkrootfs: FreeBSD file $rel not found" >&2
            return 0
        }
        echo "$rel" >> "$WORK/.fbsd-$$"
        mkdir -p "$WORK/$(dirname "$rel")"
        cp -L "$src" "$WORK/$rel"
        for lib in $(readelf -d "$src" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
            libpath="$(fbsd_findlib "$lib")" || {
                echo "mkrootfs: $rel needs $lib, not found" >&2
                continue
            }
            grep -qx "$libpath" "$WORK/.fbsd-$$" 2>/dev/null || fbsd_install "$libpath"
        done
    }

    : > "$WORK/.fbsd-$$"
    fbsd_install libexec/ld-elf.so.1
    for prog in $FBSD_PROGS; do
        fbsd_install "$prog"
    done
    for prog in $FBSD_PKG_PROGS; do
        [ -e "$PKGROOT/$prog" ] && fbsd_install "$prog"
    done
    for mod in $FBSD_PAM; do
        fbsd_install "usr/lib/$mod.so.6"
        ln -sf "$mod.so.6" "$WORK/usr/lib/$mod.so"
    done
    mv "$WORK/.fbsd-$$" "$WORK/.fbsd-list"

    # The native shell stays as /bin/renux-sh; /bin/test also answers to [.
    ln -sf test "$WORK/bin/["

    # A native Renux tool in /bin would shadow FreeBSD's copy of the same
    # command in /usr/bin or a package's in /usr/local/bin (PATH searches
    # /bin first): let FreeBSD's win.
    for prog in $FBSD_PROGS $FBSD_PKG_PROGS; do
        case "$prog" in
        usr/bin/* | usr/local/bin/*)
            name="${prog##*/}"
            [ -e "$WORK/$prog" ] || continue
            [ -e "$WORK/bin/$name" ] && ! grep -qx "bin/$name" "$WORK/.fbsd-list" && rm -f "$WORK/bin/$name"
            ;;
        esac
    done
    # Renux's own nano is also installed as "edit"; GNU nano replaces both.
    [ -e "$WORK/usr/local/bin/nano" ] && rm -f "$WORK/bin/edit"
    rm -f "$WORK/.fbsd-list"

    # Configuration the login path reads: accounts (passwd and its databases),
    # login classes, PAM, the getty table, name service switch, shells and
    # the shell profiles. The accounts are FreeBSD's defaults: root has no
    # password, as on a fresh FreeBSD install.
    mkdir -p "$WORK/etc/pam.d" "$WORK/root" "$WORK/usr/share/misc" "$WORK/var/run" "$WORK/var/log"
    for f in gettytab passwd master.passwd pwd.db spwd.db group login.conf \
        login.conf.db login.access nsswitch.conf shells profile ttys; do
        [ -e "$FBSDLIB/etc/$f" ] && cp -L "$FBSDLIB/etc/$f" "$WORK/etc/$f"
    done
    for f in login system other passwd su; do
        cp "$FBSDLIB/etc/pam.d/$f" "$WORK/etc/pam.d/$f"
    done
    for f in .profile .shrc .cshrc .login; do
        cp "$FBSDLIB/root/$f" "$WORK/root/$f"
    done
    chmod 700 "$WORK/root"
    chmod 600 "$WORK/etc/master.passwd" "$WORK/etc/spwd.db"
    # The terminal database (ncurses reads termcap on FreeBSD); /etc/termcap
    # is a link to it, as on FreeBSD.
    cp "$FBSDLIB/usr/share/misc/termcap" "$FBSDLIB/usr/share/misc/termcap.db" "$WORK/usr/share/misc/"
    ln -sf /usr/share/misc/termcap "$WORK/etc/termcap"
    # The C.UTF-8 locale, FreeBSD's default (login.conf's lang=C.UTF-8), so
    # the shell and the utilities handle UTF-8 text.
    if [ -d "$FBSDLIB/usr/share/locale/C.UTF-8" ]; then
        mkdir -p "$WORK/usr/share/locale"
        cp -R "$FBSDLIB/usr/share/locale/C.UTF-8" "$WORK/usr/share/locale/"
    fi
    [ -e "$FBSDLIB/usr/share/games/fortune/freebsd-tips.dat" ] && {
        mkdir -p "$WORK/usr/share/games/fortune"
        cp "$FBSDLIB"/usr/share/games/fortune/freebsd-tips* "$WORK/usr/share/games/fortune/"
    }
    # bash (GPL) as root's login shell when the package is present, as
    # chsh(1) would set it: the shell field of the account, /etc/shells, and
    # the password databases rebuilt by pwd_mkdb(8) at boot (/etc/rc), since
    # it is a FreeBSD program and does not run on the build host.
    if [ -e "$WORK/usr/local/bin/bash" ]; then
        sed -i 's|^\(root:[^:]*:0:0:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*\):/bin/sh$|\1:/usr/local/bin/bash|' "$WORK/etc/master.passwd"
        sed -i 's|^\(root:[^:]*:0:0:[^:]*:[^:]*\):/bin/sh$|\1:/usr/local/bin/bash|' "$WORK/etc/passwd"
        grep -qx /usr/local/bin/bash "$WORK/etc/shells" || echo /usr/local/bin/bash >> "$WORK/etc/shells"
        rm -f "$WORK/etc/pwd.db" "$WORK/etc/spwd.db"
        cp "$FBSDLIB/root/.profile" "$WORK/root/.bash_profile"
    fi

    # The message of the day login(1) shows (login.conf's welcome=).
    cp "$ROOT/etc/motd.template" "$WORK/var/run/motd"
    : > "$WORK/var/log/utx.log"
    cp "$FBSDLIB/COPYRIGHT" "$WORK/COPYRIGHT.FreeBSD"
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
