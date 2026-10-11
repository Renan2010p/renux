/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * Time declarations.
 */

#ifndef _ZENBSD_TIME_H_
#define _ZENBSD_TIME_H_

struct timeval {
    long tv_sec;
    long tv_usec;
};

typedef long time_t;

time_t time(time_t *t);
int gettimeofday(struct timeval *tv, void *tz);
char *ctime(const time_t *t);

#endif /* _ZENBSD_TIME_H_ */
