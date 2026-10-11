/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Minimal stdio declarations.
 */

#ifndef _ZENBSD_STDIO_H_
#define _ZENBSD_STDIO_H_

#include <stddef.h>

typedef struct __zenbsd_FILE FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
int fgetc(FILE *f);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f);
char *fgets(char *s, int n, FILE *f);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f);
int fputc(int c, FILE *f);
int fputs(const char *s, FILE *f);
int fflush(FILE *f);
int feof(FILE *f);
int ferror(FILE *f);

int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int puts(const char *s);
int putchar(int c);
int getchar(void);

#endif /* _ZENBSD_STDIO_H_ */
