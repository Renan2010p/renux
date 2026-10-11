#ifndef _UNISTD_H_
#define _UNISTD_H_
#include <sys/types.h>
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int close(int);
int open(const char *, int, ...);
off_t lseek(int, off_t, int);
int unlink(const char *);
char *getcwd(char *, size_t);
int issetugid(void);
int __getosreldate(void);
uid_t geteuid(void);
gid_t getegid(void);
uid_t getuid(void);
pid_t getpid(void);
void _exit(int) __attribute__((noreturn));
#endif
