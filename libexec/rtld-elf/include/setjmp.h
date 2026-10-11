#ifndef _SETJMP_H_
#define _SETJMP_H_
typedef long jmp_buf[8];
int setjmp(jmp_buf);
void longjmp(jmp_buf, int) __attribute__((noreturn));
#endif
typedef long sigjmp_buf[8];
int sigsetjmp(sigjmp_buf, int);
void siglongjmp(sigjmp_buf, int) __attribute__((noreturn));
