/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * File status declarations, matching FreeBSD/amd64's struct stat (the ABI
 * Renux exposes) and the kernel's struct stat.  Plain integer types are used
 * so the header needs no <sys/types.h>.
 */

#ifndef _RENUX_SYS_STAT_H_
#define _RENUX_SYS_STAT_H_

#ifndef _RENUX_STRUCT_TIMESPEC
#define _RENUX_STRUCT_TIMESPEC
struct timespec {
    long tv_sec;
    long tv_nsec;
};
#endif

struct stat {
    unsigned long st_dev;
    unsigned long st_ino;
    unsigned long st_nlink;
    unsigned short st_mode;
    short st_padding0;
    unsigned int st_uid;
    unsigned int st_gid;
    int st_padding1;
    unsigned long st_rdev;
    struct timespec st_atim;
    struct timespec st_mtim;
    struct timespec st_ctim;
    long st_size;
    long st_blocks;
    int st_blksize;
    unsigned int st_flags;
    unsigned int st_gen;
    unsigned int st_lspare;
    struct timespec st_birthtim;
};

#define S_IFMT 0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_IFCHR 0020000
#define S_IFBLK 0060000
#define S_IFLNK 0120000
#define S_IFIFO 0010000

#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m) (((m) & S_IFMT) == S_IFBLK)
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)

int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);

#endif /* _RENUX_SYS_STAT_H_ */
