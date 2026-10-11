/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * errno and strerror.
 */

#ifndef _ZENBSD_ERRNO_H_
#define _ZENBSD_ERRNO_H_

extern int errno;

#define EPERM 1
#define ENOENT 2
#define EIO 5
#define EBADF 9
#define EAGAIN 11
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define EEXIST 17
#define ENOTDIR 20
#define EISDIR 21
#define EINVAL 22
#define ENOTTY 25
#define ENOSPC 28
#define ESPIPE 29
#define EROFS 30

char *strerror(int code);

#endif /* _ZENBSD_ERRNO_H_ */
