#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Renux Project
#
# mkdisk.sh -- create the persistent disk Renux mounts on /home.
#
# Usage: mkdisk.sh [image] [size]      (defaults: disk.img, 1G)
#
# The image is a sparse file holding an ext2 file system, attached to QEMU
# as a virtio disk (/dev/vtbd0 in Renux). It is created only when it does
# not exist yet: once made, it holds your files, and a rebuild never touches
# it. Delete it by hand to start over. On the host, e2fsck(8) checks it and
# debugfs(8) looks inside.

set -e
IMG="${1:-disk.img}"
SIZE="${2:-1G}"

[ -e "$IMG" ] && exit 0

command -v mke2fs >/dev/null 2>&1 || {
    echo "mkdisk: 'mke2fs' (e2fsprogs) is required" >&2
    exit 1
}
truncate -s "$SIZE" "$IMG"
# ext2 with 4 KiB blocks; 1% reserved for root, as on a FreeBSD UFS /home.
mke2fs -q -t ext2 -b 4096 -m 1 -L renux-home "$IMG"
echo "mkdisk: $IMG ($SIZE, ext2) created"
