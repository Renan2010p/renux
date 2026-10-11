/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Terminal attributes, matching the kernel's struct termios.
 */

#ifndef _ZENBSD_TERMIOS_H_
#define _ZENBSD_TERMIOS_H_

#define NCCS 20

struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
    unsigned char c_cc[NCCS];
    unsigned int c_ispeed;
    unsigned int c_ospeed;
};

/* c_lflag bits (the subset in use). */
#define ECHO 0x00000008
#define ISIG 0x00000080
#define ICANON 0x00000100

/* c_cc indices. */
#define VEOF 0
#define VERASE 3
#define VINTR 7
#define VQUIT 8
#define VSUSP 9
#define VMIN 16
#define VTIME 17

#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2

int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int action, const struct termios *t);
int isatty(int fd);

#endif /* _ZENBSD_TERMIOS_H_ */
