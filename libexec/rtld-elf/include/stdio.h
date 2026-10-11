#ifndef _STDIO_H_
#define _STDIO_H_
#include <stddef.h>
#include <stdarg.h>
int snprintf(char *, size_t, const char *, ...);
int vsnprintf(char *, size_t, const char *, va_list);
#endif
