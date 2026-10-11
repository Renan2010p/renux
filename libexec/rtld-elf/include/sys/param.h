#ifndef _SYS_PARAM_H_
#define _SYS_PARAM_H_
#include <sys/types.h>
#include <limits.h>
#include <machine/param.h>
#include <sys/endian.h>
#define __FreeBSD_version 1400090
#ifndef MAXPATHLEN
#define MAXPATHLEN 1024
#endif
#define PAGE_SHIFT 12
#define PAGE_SIZE (1 << PAGE_SHIFT)
#define PAGE_MASK (PAGE_SIZE - 1)
#define roundup(x, y) ((((x)+((y)-1))/(y))*(y))
#define rounddown(x, y) (((x)/(y))*(y))
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))
#define powerof2(x) ((((x)-1)&(x))==0)
#define NBBY 8
#include <limits.h>
#include <machine/param.h>
#include <sys/endian.h>
#ifndef PATH_MAX
#define PATH_MAX 1024
#define MAXPAGESIZES 2
#endif
#ifndef SIZE_T_MAX
#define SIZE_T_MAX ULONG_MAX
#endif
#define howmany(x,y) (((x)+((y)-1))/(y))
#define roundup2(x, y) ((__typeof__(x))((((uintptr_t)(x))+((y)-1))&(~((uintptr_t)(y)-1))))
#define rounddown2(x, y) ((__typeof__(x))(((uintptr_t)(x))&(~((uintptr_t)(y)-1))))
#endif
