/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Minimal directory-entry declarations.
 */

#ifndef _ZENBSD_DIRENT_H_
#define _ZENBSD_DIRENT_H_

struct dirent {
    unsigned long d_ino;
    long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    unsigned short d_namlen;
    char d_name[256];
};

typedef struct __zenbsd_DIR DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);

#endif /* _ZENBSD_DIRENT_H_ */
