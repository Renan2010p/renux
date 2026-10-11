#ifndef _ASSERT_H_
#define _ASSERT_H_
void abort(void) __attribute__((noreturn));
#define assert(e) ((e) ? (void)0 : abort())
#endif
