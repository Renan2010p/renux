#ifndef _SYS_UTSNAME_H_
#define _SYS_UTSNAME_H_
struct utsname { char sysname[32], nodename[32], release[32], version[32], machine[32]; };
int uname(struct utsname *);
#endif
