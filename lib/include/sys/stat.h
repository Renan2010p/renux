/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * File status declarations, matching the kernel's struct stat.
 */

#ifndef _ZENBSD_SYS_STAT_H_
#define _ZENBSD_SYS_STAT_H_

struct stat {
    unsigned long st_dev;
    unsigned long st_ino;
    unsigned int st_mode;
    unsigned int st_nlink;
    unsigned int st_uid;
    unsigned int st_gid;
    unsigned long st_rdev;
    unsigned long st_size;
    unsigned long st_blksize;
    unsigned long st_blocks;
    long st_atime;
    long st_mtime;
    long st_ctime;
};

#define S_IFMT 0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_IFCHR 0020000
#define S_IFBLK 0060000

#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)

int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);

#endif /* _ZENBSD_SYS_STAT_H_ */
