/*-
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The rtld system call layer for Renux.
 *
 * FreeBSD's rtld-elf calls a set of __sys_* wrappers that its libc normally
 * provides. Renux has no shared libc yet, so this file implements them directly
 * with the `syscall` instruction, using the FreeBSD system call numbers (which
 * the Renux kernel speaks). A failing call sets rtld's errno (rtld's __error()).
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <sys/sysctl.h>
#include <errno.h>

int *__error(void);

static long
raw(long n, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long r10 __asm__("r10") = a3;
	register long r8 __asm__("r8") = a4;
	register long r9 __asm__("r9") = a5;
	long ret;
	unsigned char cf;

	__asm__ __volatile__(
	    "syscall\n\t"
	    "setc %1"
	    : "=a"(ret), "=q"(cf)
	    : "a"(n), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
	    : "rcx", "r11", "memory");
	if (cf) {
		*__error() = (int)ret; /* the kernel returns the errno in rax */
		return (-1);
	}
	return (ret);
}

int
__sys_open(const char *path, int flags, ...)
{
	return ((int)raw(5, (long)path, flags, 0, 0, 0, 0));
}

int
__sys_openat(int dfd, const char *path, int flags, ...)
{
	(void)dfd; /* Renux only opens absolute/relative paths */
	return ((int)raw(5, (long)path, flags, 0, 0, 0, 0));
}

int
__sys_close(int fd)
{
	return ((int)raw(6, fd, 0, 0, 0, 0, 0));
}

ssize_t
__sys_read(int fd, void *buf, size_t n)
{
	return ((ssize_t)raw(3, fd, (long)buf, n, 0, 0, 0));
}

ssize_t
__sys_write(int fd, const void *buf, size_t n)
{
	return ((ssize_t)raw(4, fd, (long)buf, n, 0, 0, 0));
}

ssize_t
__sys_pread(int fd, void *buf, size_t n, off_t off)
{
	/* No pread(2) in the kernel yet: seek and read. */
	if (raw(19, fd, off, 0, 0, 0, 0) < 0)
		return (-1);
	return ((ssize_t)raw(3, fd, (long)buf, n, 0, 0, 0));
}

void
__sys__exit(int code)
{
	(void)raw(1, code, 0, 0, 0, 0, 0);
	for (;;) {
	}
}

int
__sys_fcntl(int fd, int cmd, ...)
{
	(void)fd;
	(void)cmd;
	return (-1); /* not implemented */
}

int
__sys_sigprocmask(int how, const sigset_t *set, sigset_t *oset)
{
	return ((int)raw(340, how, (long)set, (long)oset, 0, 0, 0));
}

int
__sys_sigfastblock(int op, void *ptr)
{
	(void)op;
	(void)ptr;
	return (0);
}

int
__sys___sysctl(const int *name, u_int namelen, void *oldp, size_t *oldlenp,
    const void *newp, size_t newlen)
{
	(void)namelen;
	(void)newp;
	(void)newlen;

	/* The few values rtld reads; everything else is unsupported. */
	if (namelen >= 2 && name[0] == CTL_KERN && name[1] == KERN_OSRELDATE) {
		if (oldp != 0 && oldlenp != 0 && *oldlenp >= sizeof(int)) {
			*(int *)oldp = 1400090;
			*oldlenp = sizeof(int);
			return (0);
		}
	}
	if (namelen >= 2 && name[0] == CTL_HW && name[1] == HW_PAGESIZE) {
		if (oldp != 0 && oldlenp != 0 && *oldlenp >= sizeof(int)) {
			*(int *)oldp = 4096;
			*oldlenp = sizeof(int);
			return (0);
		}
	}
	*__error() = ENOENT;
	return (-1);
}

int
sysarch(int op, void *parms)
{
	return ((int)raw(165, op, (long)parms, 0, 0, 0, 0));
}

void *
__sys_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	long r = raw(477, (long)addr, len, prot, flags, fd, off);
	if (r == -1)
		return (MAP_FAILED);
	return ((void *)r);
}

int
__sys_munmap(void *addr, size_t len)
{
	return ((int)raw(73, (long)addr, len, 0, 0, 0, 0));
}

int
__sys_mprotect(void *addr, size_t len, int prot)
{
	return ((int)raw(74, (long)addr, len, prot, 0, 0, 0));
}

int
__sys_fstat(int fd, struct stat *st)
{
	return ((int)raw(551, fd, (long)st, 0, 0, 0, 0));
}

int
__sys___getcwd(char *buf, size_t len)
{
	return ((int)raw(326, (long)buf, len, 0, 0, 0, 0));
}

int
__sys_getpid(void)
{
	return ((int)raw(20, 0, 0, 0, 0, 0, 0));
}

int
__sys_geteuid(void)
{
	return ((int)raw(24, 0, 0, 0, 0, 0, 0));
}

int
__sys_getegid(void)
{
	return ((int)raw(24, 0, 0, 0, 0, 0, 0));
}

int
__sys_kill(int pid, int sig)
{
	return ((int)raw(37, pid, sig, 0, 0, 0, 0));
}

long
__sys_getdirentries(int fd, char *buf, size_t n, off_t *basep)
{
	(void)basep;
	return (raw(272, fd, (long)buf, n, 0, 0, 0));
}

/* utrace is a no-op without kernel tracing. */
void
utrace(const void *trace, size_t len)
{
	(void)trace;
	(void)len;
}
