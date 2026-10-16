#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# mkdisk.sh -- create the persistent disk Renux mounts on /home.
#
# Usage: mkdisk.sh [image] [mkfs]        (defaults: disk.img, mke2fs)
#
# The image is a sparse file holding an ext2 file system, attached to QEMU as
# a virtio disk (/dev/vda in Renux). It is created only when it does not exist
# yet: once made, it holds your files, and a rebuild never touches it. The
# filesystem is written by our own mkfs (tools/mkfs.zig); on the host e2fsck(8)
# checks it and debugfs(8) looks inside.

set -e
IMG="${1:-disk.img}"
MKFS="${2:-mke2fs}"

[ -e "$IMG" ] && exit 0

[ -x "$MKFS" ] || command -v "$MKFS" >/dev/null 2>&1 || {
    echo "mkdisk: the ext2 writer '$MKFS' is required" >&2
    exit 1
}

# 1 GiB, ext2, 4 KiB blocks, 1% reserved for root (as on a FreeBSD UFS /home).
"$MKFS" -b 4096 -m 1 -L renux-home "$IMG" 262144 || {
    echo "mkdisk: mkfs failed" >&2
    exit 1
}
echo "mkdisk: $IMG (1G, ext2) created"
