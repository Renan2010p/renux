/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Minimal stdio declarations.
 */

#ifndef _ZENBSD_STDIO_H_
#define _ZENBSD_STDIO_H_

int puts(const char *s);
int putchar(int c);
int getchar(void);
int printf(const char *fmt, ...);

#endif /* _ZENBSD_STDIO_H_ */
