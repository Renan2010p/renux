/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
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

#endif /* _ZENBSD_STDLIB_H_ */
