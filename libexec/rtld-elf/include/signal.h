#ifndef _SIGNAL_H_
#define _SIGNAL_H_
#include <sys/types.h>
struct sigaction { void (*sa_handler)(int); sigset_t sa_mask; int sa_flags; };
#define SIG_BLOCK 1
#define SIG_UNBLOCK 2
#define SIG_SETMASK 3
#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
int sigprocmask(int, const sigset_t *, sigset_t *);
int sigaction(int, const struct sigaction *, struct sigaction *);
int raise(int);
int sigfillset(sigset_t *);
#define SIGFASTBLOCK_FLAGS 0
#endif
#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGTRAP 5
#define SIGABRT 6
#define SIGBUS 10
#define SIGSEGV 11
#define SIGSYS 12
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGFASTBLOCK_INC 0
#define SIGFASTBLOCK_PEND 0
#define SIGFASTBLOCK_UNBLOCK 0
#define SIGFASTBLOCK_UNSETPTR 0
#define SIGFASTBLOCK_SETMASK 0
#define SIGFASTBLOCK_SETPTR 0
