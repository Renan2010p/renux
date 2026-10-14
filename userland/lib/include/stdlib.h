/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * Minimal stdlib declarations.
 */

#ifndef _ZENBSD_STDLIB_H_
#define _ZENBSD_STDLIB_H_

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t n, size_t size);
void free(void *ptr);
int atoi(const char *s);
void exit(int status) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));

extern char **environ;
char *getenv(const char *name);

#include <stddef.h>
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);
int munmap(void *addr, size_t len);

#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define MAP_PRIVATE 0x0002
#define MAP_ANON 0x1000

#endif /* _ZENBSD_STDLIB_H_ */
