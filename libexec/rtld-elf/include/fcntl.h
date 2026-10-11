#ifndef _FCNTL_H_
#define _FCNTL_H_
#include <sys/types.h>
#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR 0x0002
#define O_ACCMODE 0x0003
#define O_NONBLOCK 0x0004
#define O_APPEND 0x0008
#define O_CREAT 0x0200
#define O_TRUNC 0x0400
#define O_EXCL 0x0800
#define O_CLOEXEC 0x100000
#define FD_CLOEXEC 1
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define F_DUPFD_CLOEXEC 17
#define O_VERIFY 0x200000
int open(const char *, int, ...);
int fcntl(int, int, ...);
#endif
