#ifndef _DLFCN_H_
#define _DLFCN_H_
#include <stddef.h>
#include <link.h>
#define RTLD_LAZY 1
#define RTLD_NOW 2
#define RTLD_MODEMASK 0x3
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL 0
#define RTLD_TRACE 0x200
#define RTLD_NODELETE 0x01000
#define RTLD_NOLOAD 0x02000
#define RTLD_DEEPBIND 0x04000
#define RTLD_DEFAULT ((void *)0)
#define RTLD_NEXT ((void *)-1LL)
#define RTLD_SELF ((void *)-3LL)
typedef void (*dlfunc_t)(void);
typedef struct Dl_info {
	const char *dli_fname;
	void *dli_fbase;
	const char *dli_sname;
	void *dli_saddr;
} Dl_info;
typedef int (*__dl_iterate_hdr_callback)(struct dl_phdr_info *, size_t, void *);
void *dlopen(const char *, int);
void *fdlopen(int, int);
void *dlsym(void *, const char *);
void *dlvsym(void *, const char *, const char *);
int dlclose(void *);
char *dlerror(void);
dlfunc_t dlfunc(void *, const char *);
int dladdr(const void *, Dl_info *);
int dladdr1(const void *, Dl_info *, void **, int);
int dl_iterate_phdr(__dl_iterate_hdr_callback, void *);
int dlinfo(void *, int, void *);
#define RTLD_DI_LINKMAP 2

struct dl_serpath { char *dls_name; unsigned int dls_flags; };
struct dl_serinfo { size_t dls_size; unsigned int dls_cnt; struct dl_serpath dls_serpath[1]; };
#define RTLD_DI_LINKMAP 2
#define RTLD_DI_SERINFO 0x1004
#define RTLD_DI_SERINFOSIZE 0x1005
#define RTLD_DI_ORIGIN 0x1006

#endif
