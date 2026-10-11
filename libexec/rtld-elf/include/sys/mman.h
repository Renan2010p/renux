#ifndef _SYS_MMAN_H_
#define _SYS_MMAN_H_
#include <sys/types.h>
#define PROT_NONE 0x0
#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define PROT_EXEC 0x4
#define MAP_SHARED 0x0001
#define MAP_PRIVATE 0x0002
#define MAP_FIXED 0x0010
#define MAP_ANON 0x1000
#define MAP_ANONYMOUS MAP_ANON
#define MAP_FAILED ((void *)-1)
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
int mprotect(void *, size_t, int);
#endif
#ifndef MAP_EXCL
#define MAP_EXCL 0x00004000
#define MAP_NOCORE 0x00020000
#endif
#ifndef MAP_GUARD
#define MAP_GUARD 0x00008000
#endif
#ifndef MAP_PREFAULT_READ
#define MAP_PREFAULT_READ 0x00040000
#endif
#ifndef MAP_ALIGNED_SUPER
#define MAP_ALIGNED_SUPER 0x200000000ULL
#endif
