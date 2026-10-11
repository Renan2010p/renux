/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * edit: a small full-screen editor built on the minimal curses.
 *
 *   arrows   move
 *   ^S       save
 *   ^Q       quit
 */

#include <curses.h>
#include <stdio.h>
#include <string.h>

#define MAXTEXT (64 * 1024)

static char text[MAXTEXT];
static long tlen = 0;
static long cur = 0;
static int modified = 0;
static const char *fname = "untitled";

static void load(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == 0) {
        return;
    }
    long n = (long)fread(text, 1, MAXTEXT, f);
    tlen = (n > 0) ? n : 0;
    fclose(f);
}

static void save(void) {
    FILE *f = fopen(fname, "w");
    if (f == 0) {
        return;
    }
    fwrite(text, 1, (unsigned long)tlen, f);
    fclose(f);
    modified = 0;
}

static void insert(char c) {
    if (tlen + 1 >= MAXTEXT) {
        return;
    }
    for (long i = tlen; i > cur; i--) {
        text[i] = text[i - 1];
    }
    text[cur] = c;
    cur++;
    tlen++;
    modified = 1;
}

static void backspace(void) {
    if (cur == 0) {
        return;
    }
    for (long i = cur - 1; i < tlen - 1; i++) {
        text[i] = text[i + 1];
    }
    cur--;
    tlen--;
    modified = 1;
}

/* Column of the cursor within its line, and the line number (0-based). */
static void cursorPos(int *line, int *col) {
    int l = 0;
    long ls = 0;
    for (long i = 0; i < cur; i++) {
        if (text[i] == '\n') {
            l++;
            ls = i + 1;
        }
    }
    *line = l;
    *col = (int)(cur - ls);
}

/* Byte offset of the start of `line` (0-based). */
static long lineStart(int line) {
    long p = 0;
    int l = 0;
    while (p < tlen && l < line) {
        if (text[p] == '\n') {
            l++;
        }
        p++;
    }
    return p;
}

static void moveVertical(int delta) {
    int line, col;
    cursorPos(&line, &col);
    int target = line + delta;
    if (target < 0) {
        target = 0;
    }
    long start = lineStart(target);
    long end = start;
    while (end < tlen && text[end] != '\n') {
        end++;
    }
    long want = start + col;
    if (want > end) {
        want = end;
    }
    cur = want;
}

static void render(void) {
    int line, col;
    cursorPos(&line, &col);

    int rows = LINES - 1;
    int top = 0;
    if (line >= rows) {
        top = line - rows + 1;
    }

    clear();
    long p = lineStart(top);
    int row = 0;
    while (row < rows && p <= tlen) {
        move(row, 0);
        long q = p;
        while (q < tlen && text[q] != '\n') {
            addch(text[q]);
            q++;
        }
        row++;
        if (q < tlen && text[q] == '\n') {
            p = q + 1;
        } else {
            break;
        }
    }

    char status[160];
    snprintf(status, sizeof(status), " %s%s  L%d C%d  ^S save  ^Q quit",
             fname, modified ? " *" : "", line + 1, col + 1);
    move(LINES - 1, 0);
    addstr(status);

    move(line - top, col);
    refresh();
}

int main(int argc, char **argv) {
    if (argc > 1) {
        fname = argv[1];
        load(fname);
    }

    initscr();
    noecho();
    keypad(stdscr, 1);

    for (;;) {
        render();
        int c = getch();
        if (c == ERR) {
            continue;
        }
        if (c == 0x11) {
            break; /* ^Q */
        } else if (c == 0x13) {
            save(); /* ^S */
        } else if (c == KEY_LEFT) {
            if (cur > 0) {
                cur--;
            }
        } else if (c == KEY_RIGHT) {
            if (cur < tlen) {
                cur++;
            }
        } else if (c == KEY_UP) {
            moveVertical(-1);
        } else if (c == KEY_DOWN) {
            moveVertical(1);
        } else if (c == 0x7f || c == 0x08) {
            backspace();
        } else if (c == '\r' || c == '\n') {
            insert('\n');
        } else if (c >= 32 && c < 127) {
            insert((char)c);
        }
    }

    endwin();
    return 0;
}
