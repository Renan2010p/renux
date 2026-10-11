/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Signal declarations.
 */

#ifndef _ZENBSD_SIGNAL_H_
#define _ZENBSD_SIGNAL_H_

typedef void (*sighandler_t)(int);

struct sigaction {
    sighandler_t sa_handler;
    unsigned long sa_mask;
};

#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)

#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGKILL 9
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGCHLD 20
#define SIGWINCH 28
#define SIGUSR1 30
#define SIGUSR2 31

sighandler_t signal(int sig, sighandler_t handler);
int sigaction(int sig, const struct sigaction *act, struct sigaction *oact);

#endif /* _ZENBSD_SIGNAL_H_ */
