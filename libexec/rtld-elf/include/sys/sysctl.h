#ifndef _SYS_SYSCTL_H_
#define _SYS_SYSCTL_H_
#include <sys/types.h>
#define CTL_KERN 1
#define CTL_HW 6
#define CTL_USER 8
#define USER_TZNAME_MAX 9
#define USER_CS_PATH 1
#define KERN_PROC 14
#define KERN_PROC_OSREL 34
#define KERN_OSRELDATE 12
#define KERN_USRSTACK 33
#define HW_MACHINE 1
#define HW_MACHINE_ARCH 27
int __sysctl(const int *, u_int, void *, size_t *, const void *, size_t);
int sysctl(const int *, u_int, void *, size_t *, const void *, size_t);
#endif
#define HW_PAGESIZE 7
int sysctlnametomib(const char *, int *, size_t *);
