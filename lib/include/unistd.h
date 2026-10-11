/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * POSIX-like declarations for the C library.
 *
 * Only what the C programs built so far use; the types match the machine
 * (long is 64-bit on amd64). clang provides stddef.h/stdint.h itself.
 */

#ifndef _ZENBSD_UNISTD_H_
#define _ZENBSD_UNISTD_H_

#include <stddef.h>

typedef long ssize_t;
typedef long off_t;

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR 0x0002
#define O_CREAT 0x0200
#define O_TRUNC 0x0400
#define O_DIRECTORY 0x20000

ssize_t write(int fd, const void *buf, size_t n);
ssize_t read(int fd, void *buf, size_t n);
int open(const char *path, int flags, int mode);
int close(int fd);
off_t lseek(int fd, off_t off, int whence);
int chdir(const char *path);
int mkdir(const char *path, int mode);
int rmdir(const char *path);
int unlink(const char *path);
int getpid(void);
int getuid(void);
int setuid(int uid);
void _exit(int status) __attribute__((noreturn));
int isatty(int fd);

extern int optind;
extern char *optarg;
extern int optopt;
extern int opterr;
int getopt(int argc, char *const argv[], const char *optstring);

#endif /* _ZENBSD_UNISTD_H_ */
