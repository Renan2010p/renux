/*-
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * A minimal libc for rtld-elf.
 *
 * FreeBSD's rtld links a small set of libc functions. Renux has no shared libc
 * yet, so the ones rtld uses are provided here, delegating the system calls to
 * the __sys_* layer (the Renux/FreeBSD ABI).
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/utsname.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>

static size_t strnlen_simple(const char *s, size_t n);

int errno;
int sys_nerr = 0;
const char *const sys_errlist[1] = { "unknown error" };

extern void *__sys_mmap(void *, size_t, int, int, int, off_t);
extern int __sys_munmap(void *, size_t);
extern int __sys_mprotect(void *, size_t, int);
extern int __sys_fstat(int, struct stat *);
extern int __sys___getcwd(char *, size_t);
extern int __sys_getpid(void);
extern int __sys_geteuid(void);
extern int __sys_getegid(void);
extern int __sys_kill(int, int);
extern long __sys_getdirentries(int, char *, size_t, off_t *);

/* -- memory --------------------------------------------------------------- */

void *
memcpy(void *dst, const void *src, size_t n)
{
	char *d = dst;
	const char *s = src;
	for (size_t i = 0; i < n; i++)
		d[i] = s[i];
	return (dst);
}

void *
memmove(void *dst, const void *src, size_t n)
{
	char *d = dst;
	const char *s = src;
	if (d < s)
		for (size_t i = 0; i < n; i++)
			d[i] = s[i];
	else
		for (size_t i = n; i > 0; i--)
			d[i - 1] = s[i - 1];
	return (dst);
}

void *
memset(void *dst, int c, size_t n)
{
	char *d = dst;
	for (size_t i = 0; i < n; i++)
		d[i] = (char)c;
	return (dst);
}

void
bzero(void *dst, size_t n)
{
	memset(dst, 0, n);
}

void
bcopy(const void *src, void *dst, size_t n)
{
	memmove(dst, src, n);
}

void *
mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	return (__sys_mmap(addr, len, prot, flags, fd, off));
}

int
munmap(void *addr, size_t len)
{
	return (__sys_munmap(addr, len));
}

int
mprotect(void *addr, size_t len, int prot)
{
	return (__sys_mprotect(addr, len, prot));
}

/* -- strings -------------------------------------------------------------- */

size_t
strlen(const char *s)
{
	const char *p = s;
	while (*p)
		p++;
	return (p - s);
}

int
strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return ((unsigned char)*a - (unsigned char)*b);
}

int
strncmp(const char *a, const char *b, size_t n)
{
	while (n && *a && *a == *b) {
		a++;
		b++;
		n--;
	}
	if (n == 0)
		return (0);
	return ((unsigned char)*a - (unsigned char)*b);
}

char *
strcpy(char *d, const char *s)
{
	char *r = d;
	while ((*d++ = *s++) != 0) {
	}
	return (r);
}

char *
strncpy(char *d, const char *s, size_t n)
{
	size_t i = 0;
	for (; i < n && s[i]; i++)
		d[i] = s[i];
	for (; i < n; i++)
		d[i] = 0;
	return (d);
}

char *
strcat(char *d, const char *s)
{
	char *r = d;
	while (*d)
		d++;
	while ((*d++ = *s++) != 0) {
	}
	return (r);
}

char *
strchr(const char *s, int c)
{
	for (;; s++) {
		if (*s == (char)c)
			return ((char *)s);
		if (*s == 0)
			return (NULL);
	}
}

char *
strrchr(const char *s, int c)
{
	const char *last = NULL;
	for (;; s++) {
		if (*s == (char)c)
			last = s;
		if (*s == 0)
			return ((char *)last);
	}
}

char *
strstr(const char *h, const char *n)
{
	if (*n == 0)
		return ((char *)h);
	for (; *h; h++) {
		const char *a = h, *b = n;
		while (*a && *b && *a == *b) {
			a++;
			b++;
		}
		if (*b == 0)
			return ((char *)h);
	}
	return (NULL);
}

size_t
strspn(const char *s, const char *set)
{
	size_t n = 0;
	for (; s[n]; n++) {
		const char *p;
		for (p = set; *p && *p != s[n]; p++) {
		}
		if (*p == 0)
			break;
	}
	return (n);
}

size_t
strcspn(const char *s, const char *set)
{
	size_t n = 0;
	for (; s[n]; n++) {
		const char *p;
		for (p = set; *p && *p != s[n]; p++) {
		}
		if (*p != 0)
			break;
	}
	return (n);
}

size_t
strlcpy(char *d, const char *s, size_t n)
{
	size_t slen = strlen(s);
	if (n != 0) {
		size_t c = slen < n - 1 ? slen : n - 1;
		for (size_t i = 0; i < c; i++)
			d[i] = s[i];
		d[c] = 0;
	}
	return (slen);
}

size_t
strlcat(char *d, const char *s, size_t n)
{
	size_t dlen = strnlen_simple(d, n);
	size_t slen = strlen(s);
	if (dlen == n)
		return (n + slen);
	strlcpy(d + dlen, s, n - dlen);
	return (dlen + slen);
}

size_t
strnlen_simple(const char *s, size_t n)
{
	size_t i = 0;
	while (i < n && s[i])
		i++;
	return (i);
}

char *
strdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = malloc(n);
	if (p)
		memcpy(p, s, n);
	return (p);
}

char *
strtok_r(char *s, const char *delim, char **save)
{
	if (s == NULL)
		s = *save;
	s += strspn(s, delim);
	if (*s == 0) {
		*save = s;
		return (NULL);
	}
	char *tok = s;
	s += strcspn(s, delim);
	if (*s) {
		*s = 0;
		s++;
	}
	*save = s;
	return (tok);
}

char *
strsep(char **sp, const char *delim)
{
	char *s = *sp;
	if (s == NULL)
		return (NULL);
	char *tok = s;
	s += strcspn(s, delim);
	if (*s) {
		*s = 0;
		s++;
	} else {
		s = NULL;
	}
	*sp = s;
	return (tok);
}

/* -- process / fs --------------------------------------------------------- */

int
getpid(void)
{
	return (__sys_getpid());
}

extern int __sys_open(const char *, int, ...);
extern int __sys_close(int);

int
open(const char *path, int flags, ...)
{
	return (__sys_open(path, flags));
}

int
close(int fd)
{
	return (__sys_close(fd));
}

uid_t
geteuid(void)
{
	return (__sys_geteuid());
}

gid_t
getegid(void)
{
	return (__sys_getegid());
}

int
issetugid(void)
{
	return (0);
}

int
fstat(int fd, struct stat *st)
{
	return (__sys_fstat(fd, st));
}

int
fstatfs(int fd, struct statfs *st)
{
	(void)fd;
	(void)st;
	return (-1);
}

char *
getcwd(char *buf, size_t len)
{
	if (__sys___getcwd(buf, len) != 0)
		return (NULL);
	return (buf);
}

char *
realpath(const char *path, char *resolved)
{
	/* No symlinks yet: copy the (absolute) path. */
	size_t n = strlen(path);
	char *out = resolved != NULL ? resolved : malloc(n + 1);
	if (out != NULL)
		memcpy(out, path, n + 1);
	return (out);
}

int
uname(struct utsname *u)
{
	static const char name[] = "Renux";
	if (u == NULL)
		return (-1);
	for (size_t i = 0; i < sizeof(u->sysname); i++)
		u->sysname[i] = i < sizeof(name) ? name[i] : 0;
	for (size_t f = 0; f < 4; f++) {
		char *dst = ((char *)u) + 32 * (f + 1);
		for (size_t i = 0; i < 32; i++)
			dst[i] = 0;
	}
	return (0);
}

int
sysctlnametomib(const char *name, int *mibp, size_t *sizep)
{
	(void)name;
	(void)mibp;
	(void)sizep;
	return (-1);
}

int
raise(int sig)
{
	return (__sys_kill(__sys_getpid(), sig));
}

int
sigfillset(sigset_t *set)
{
	for (size_t i = 0; i < sizeof(*set); i++)
		((char *)set)[i] = (char)0xff;
	return (0);
}

/* -- directories ---------------------------------------------------------- */

struct __dir {
	int fd;
	char buf[4096];
	long len;
	long pos;
	struct dirent ent;
};

DIR *
opendir(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return (NULL);
	struct __dir *d = malloc(sizeof(*d));
	if (d == NULL) {
		close(fd);
		return (NULL);
	}
	d->fd = fd;
	d->len = 0;
	d->pos = 0;
	return ((DIR *)d);
}

struct dirent *
readdir(DIR *dp)
{
	struct __dir *d = (struct __dir *)dp;
	for (;;) {
		if (d->pos + 24 <= d->len) {
			char *p = d->buf + d->pos;
			unsigned short reclen = *(unsigned short *)(p + 16);
			unsigned short namlen = *(unsigned short *)(p + 20);
			if (reclen == 0)
				break;
			d->ent.d_ino = *(unsigned long *)p;
			d->ent.d_off = *(long *)(p + 8);
			d->ent.d_reclen = reclen;
			d->ent.d_type = *(unsigned char *)(p + 18);
			d->ent.d_namlen = namlen;
			for (unsigned i = 0; i < namlen && i < 255; i++)
				d->ent.d_name[i] = p[24 + i];
			d->ent.d_name[namlen < 255 ? namlen : 255] = 0;
			d->pos += reclen;
			return (&d->ent);
		}
		long n = __sys_getdirentries(d->fd, d->buf, sizeof(d->buf), NULL);
		if (n <= 0)
			return (NULL);
		d->len = n;
		d->pos = 0;
	}
	return (NULL);
}

int
closedir(DIR *dp)
{
	struct __dir *d = (struct __dir *)dp;
	int fd = d->fd;
	free(d);
	return (close(fd));
}

/* -- setjmp (for the dlopen lock recursion) ------------------------------- */

int
sigsetjmp(sigjmp_buf env, int savemask)
{
	(void)savemask;
	__asm__ __volatile__(
	    "movq %%rbx, 0(%0)\n\t"
	    "movq %%rbp, 8(%0)\n\t"
	    "movq %%r12, 16(%0)\n\t"
	    "movq %%r13, 24(%0)\n\t"
	    "movq %%r14, 32(%0)\n\t"
	    "movq %%r15, 40(%0)\n\t"
	    "leaq 8(%%rsp), %%rax\n\t"
	    "movq %%rax, 48(%0)\n\t"
	    "movq (%%rsp), %%rax\n\t"
	    "movq %%rax, 56(%0)"
	    :
	    : "r"(env)
	    : "rax", "memory");
	return (0);
}

void
siglongjmp(sigjmp_buf env, int val)
{
	__asm__ __volatile__(
	    "movq 48(%0), %%rsp\n\t"
	    "movq 56(%0), %%rax\n\t"
	    "movq %%rax, (%%rsp)\n\t"
	    "movq 0(%0), %%rbx\n\t"
	    "movq 8(%0), %%rbp\n\t"
	    "movq 16(%0), %%r12\n\t"
	    "movq 24(%0), %%r13\n\t"
	    "movq 32(%0), %%r14\n\t"
	    "movq 40(%0), %%r15\n\t"
	    :
	    : "r"(env), "S"((long)(val == 0 ? 1 : val))
	    : "memory");
	__builtin_unreachable();
}

/* -- TLS helpers ---------------------------------------------------------- */

static struct tcb { unsigned long self; unsigned long dtv[2]; } static_tcb;

void *
allocate_tls(void *objs, const void *init, size_t tcbsize, size_t tcbalign)
{
	(void)objs;
	(void)init;
	(void)tcbsize;
	(void)tcbalign;
	return (&static_tcb);
}

void
free_tls(void *tcb)
{
	(void)tcb;
}

void *
_tcb_get(void)
{
	return (&static_tcb);
}
