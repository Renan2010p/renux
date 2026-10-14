/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * A minimal curses.
 */

#ifndef _ZENBSD_CURSES_H_
#define _ZENBSD_CURSES_H_

typedef struct __renux_WINDOW WINDOW;

extern WINDOW *stdscr;
extern int LINES;
extern int COLS;

#define OK 0
#define ERR (-1)

#define A_NORMAL 0
#define A_BOLD 0x2000000

#define KEY_DOWN 258
#define KEY_UP 259
#define KEY_LEFT 260
#define KEY_RIGHT 261

WINDOW *initscr(void);
int endwin(void);
int move(int y, int x);
int addch(int c);
int addstr(const char *s);
int mvaddstr(int y, int x, const char *s);
int clear(void);
int erase(void);
int clrtoeol(void);
int refresh(void);
int wrefresh(WINDOW *w);
int attrset(int attr);
int attron(int attr);
int attroff(int attr);
int keypad(WINDOW *w, int on);
int getch(void);
int noecho(void);
int echo(void);
int cbreak(void);
int nocbreak(void);
int nodelay(WINDOW *w, int flag);

#endif /* _ZENBSD_CURSES_H_ */
