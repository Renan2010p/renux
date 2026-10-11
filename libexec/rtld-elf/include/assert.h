#ifndef _ASSERT_H_
#define _ASSERT_H_
void abort(void) __attribute__((noreturn));
void __assert(const char *, const char *, int, const char *);
#define assert(e) ((e) ? (void)0 : __assert(__func__, __FILE__, __LINE__, #e))
#endif
