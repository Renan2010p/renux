#ifndef _SYS_TYPES_H_
#define _SYS_TYPES_H_
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
typedef unsigned char	u_char;
typedef unsigned int	u_int;
typedef unsigned short	u_short;
typedef unsigned char	u_char;
typedef unsigned long	u_long;
typedef int8_t		int8_t_use;
typedef int64_t		off_t;
typedef int64_t		time_t;
typedef long		ssize_t;
typedef int		pid_t;
typedef unsigned int	uid_t;
typedef unsigned int	gid_t;
typedef unsigned short	mode_t;
typedef uint64_t	dev_t;
typedef uint64_t	ino_t;
typedef uint64_t	nlink_t;
typedef int64_t		blkcnt_t;
typedef int32_t		blksize_t;
typedef int64_t		register_t;
typedef char *		caddr_t;
typedef int		key_t;
typedef uint32_t	id_t;
typedef uint64_t	u_quad_t;
typedef int64_t		quad_t;
typedef unsigned long	uintptr_t_use;
#endif
typedef long		__ssize_t;
typedef unsigned long	__size_t;
typedef long		__off_t;
typedef unsigned char	__uint8_t;
typedef unsigned short	__uint16_t;
typedef unsigned int	__uint32_t;
typedef unsigned long	__uint64_t;
typedef signed char	__int8_t;
typedef short		__int16_t;
typedef int		__int32_t;
typedef long		__int64_t;
typedef unsigned long	__uintptr_t;
typedef long		__intptr_t;
#define NODEV ((dev_t)-1)
typedef unsigned int	__uid_t;
typedef unsigned int	__gid_t;
typedef int		__pid_t;
#ifndef __sigset_t_defined
#define __sigset_t_defined
typedef struct { unsigned int __bits[4]; } sigset_t;
#endif
