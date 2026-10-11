#ifndef _STDLIB_H_
#define _STDLIB_H_
#include <stddef.h>
void *malloc(size_t);
void free(void *);
char *getenv(const char *);
char *realpath(const char *, char *);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void abort(void) __attribute__((noreturn));
void exit(int) __attribute__((noreturn));
long strtol(const char *, char **, int);
unsigned long strtoul(const char *, char **, int);
#endif
