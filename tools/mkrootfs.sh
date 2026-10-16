#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# Build the root filesystem image that is embedded in the kernel (FreeBSD's
# MD_ROOT): stage the system into a tree, pack it into an ext2 image.
#
# Usage: mkrootfs.sh <userland> <image> [mkfs]
#
# <userland> is the native userland as `zig build` installs it
# (zig-out/userland: bin/, sbin/, usr/bin/, ...); the FreeBSD userland is
# added when it has been fetched (tools/get-freebsd.sh, get-freebsd-pkg.sh).
# The image is byte-for-byte reproducible, so an unchanged system does not
# rebuild the kernel that embeds it.
set -eu

[ $# -ge 2 ] && [ $# -le 3 ] || {
    echo "usage: mkrootfs.sh <userland> <image> [mkfs]" >&2
    exit 2
}
STAGE="$1"
OUT="$2"
MKFS="${3:-mke2fs}"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"   # tools/
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"              # repository root
ETC="$ROOT/userland/etc"
WORK="${WORK:-$(dirname -- "$OUT")/rootfs}"
# The FreeBSD base system (tools/get-freebsd.sh); used when it is present.
FBSDLIB="${FBSDLIB:-$ROOT/tools/freebsd/root}"
# FreeBSD packages (tools/get-freebsd-pkg.sh: bash, nano); used when present.
PKGROOT="${PKGROOT:-$ROOT/tools/freebsd/pkgroot}"

[ -x "$STAGE/sbin/init" ] || {
    echo "mkrootfs: no native userland in $STAGE (run 'zig build userland')" >&2
    exit 1
}

[ -x "$MKFS" ] || command -v "$MKFS" >/dev/null 2>&1 || {
    echo "mkrootfs: the ext2 writer '$MKFS' is required" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/boot" \
    "$WORK/sbin" "$WORK/bin" "$WORK/usr/bin" "$WORK/usr/sbin" "$WORK/usr/libexec" \
    "$WORK/etc" "$WORK/etc/rc.d" "$WORK/lib" "$WORK/libexec" \
    "$WORK/dev" "$WORK/tmp" "$WORK/var" "$WORK/var/log" "$WORK/var/run" \
    "$WORK/mnt" "$WORK/home"

# The native userland, at its system paths.
cp -a "$STAGE/." "$WORK/"
# The native shell stays available as /bin/renux-sh; when a FreeBSD userland is
# present it replaces /bin/sh (the default login shell). Renux's nano also
# answers to "edit".
cp -a "$WORK/bin/sh" "$WORK/bin/renux-sh"
cp -a "$WORK/bin/nano" "$WORK/bin/edit"
cp -a "$ETC/rc" "$WORK/etc/rc"
cp -a "$ETC/rc.d/syslogd" "$WORK/etc/rc.d/syslogd"
cp -a "$ETC/fstab" "$WORK/etc/fstab"

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
        usr/bin/fortune usr/bin/resizewin usr/bin/ee usr/bin/dialog usr/bin/bsddialog
        usr/sbin/pwd_mkdb sbin/ldconfig
        sbin/mount sbin/umount bin/df bin/sync bin/dd usr/bin/truncate sbin/md5
        sbin/reboot sbin/halt sbin/poweroff sbin/shutdown usr/bin/wall
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
    # FreeBSD's base "xterm" entry (tc=xterm-new) has no smcup/rmcup, so
    # full-screen programs (nano, htop, vi) cannot switch to the alternate
    # screen: on exit they leave their drawing on the normal screen. It also
    # lacks E3, the "erase the scrollback" capability clear(1) uses. Give
    # xterm both, as a terminal on Linux has, by shadowing the entry with one
    # that adds them and inherits the rest.
    {
        printf 'xterm|X11 terminal emulator:\\\n\t:E3=\\E[3J:te=\\E[?1049l:ti=\\E[?1049h:tc=xterm-new:\n'
        cat "$WORK/usr/share/misc/termcap"
    } > "$WORK/usr/share/misc/termcap.new"
    mv -f "$WORK/usr/share/misc/termcap.new" "$WORK/usr/share/misc/termcap"
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
    # The system shell is /bin/sh (FreeBSD's sh, BSD-licensed): the base
    # scripts, the single-user shell and every #!/bin/sh expect it. bash
    # (GPLv3) is a separate package -- it is offered through chsh(1) (listed
    # in /etc/shells) but is not the default login shell. /etc/passwd and
    # /etc/master.passwd already give root /bin/sh, and pwd_mkdb(8) rebuilds
    # their databases at boot (/etc/rc).
    if [ -e "$WORK/usr/local/bin/bash" ]; then
        grep -qx /usr/local/bin/bash "$WORK/etc/shells" || echo /usr/local/bin/bash >> "$WORK/etc/shells"
        # So a user who does switch to bash still has a profile it reads.
        if [ -e "$WORK/root/.profile" ] && [ ! -e "$WORK/root/.bash_profile" ]; then
            cp "$WORK/root/.profile" "$WORK/root/.bash_profile"
        fi
    fi

    # The message of the day login(1) shows (login.conf's welcome=).
    cp "$ETC/motd.template" "$WORK/var/run/motd"
    : > "$WORK/var/log/utx.log"
    cp "$FBSDLIB/COPYRIGHT" "$WORK/COPYRIGHT.FreeBSD"
fi

# Pack the tree into an ext2 image with our own mkfs (tools/mkfs.zig). It is
# deterministic -- fixed timestamps and an all-zero UUID -- so an unchanged
# userland does not force a kernel rebuild. 256-byte inodes hold timestamps
# past 2038 (128-byte ones cannot).
used_kb="$(du -sk "$WORK" | awk '{print $1}')"
blocks=$((used_kb + used_kb / 2 + 8192))
tmp="$WORK.img"
rm -f "$tmp"
"$MKFS" -b 1024 -I 256 -m 0 -i 4096 \
    -U 00000000-0000-0000-0000-000000000000 \
    -d "$WORK" "$tmp" "$blocks" || {
    echo "mkrootfs: mkfs failed" >&2
    exit 1
}

mv -f "$tmp" "$OUT"
