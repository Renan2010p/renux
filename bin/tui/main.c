/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * tui: a full-screen demo of the minimal curses.
 */

#include <curses.h>

int main(void) {
    initscr();
    noecho();
    keypad(stdscr, 1);

    clear();
    mvaddstr(3, 5, "Renux curses demo");
    mvaddstr(5, 5, "Press x to exit.");
    refresh();

    int c;
    while ((c = getch()) != 'x' && c != ERR) {
    }

    endwin();
    return 0;
}
