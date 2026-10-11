/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * nano: a small full-screen editor with a nano-like layout, built on the
 * minimal curses.
 *
 *   arrows   move
 *   ^O       write out (save)
 *   ^X       exit
 */

#include <curses.h>
#include <stdio.h>
#include <string.h>

#define MAXTEXT (64 * 1024)

static char text[MAXTEXT];
static long tlen = 0;
static long cur = 0;
static int modified = 0;
static const char *fname = "[ New File ]";

static void load(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == 0) {
        return;
    }
    long n = (long)fread(text, 1, MAXTEXT, f);
    tlen = (n > 0) ? n : 0;
    fclose(f);
}

static int save(void) {
    FILE *f = fopen(fname, "w");
    if (f == 0) {
        return -1;
    }
    fwrite(text, 1, (unsigned long)tlen, f);
    fclose(f);
    modified = 0;
    return 0;
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

static int totalLines(void) {
    int l = 1;
    for (long i = 0; i < tlen; i++) {
        if (text[i] == '\n') {
            l++;
        }
    }
    return l;
}

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

    int rows = LINES - 3; /* title + two hint lines */
    if (rows < 1) {
        rows = 1;
    }
    int top = 0;
    if (line >= rows) {
        top = line - rows + 1;
    }

    clear();

    char title[160];
    snprintf(title, sizeof(title), "  Renux nano%s     %s", modified ? " " : "",
             fname);
    move(0, 0);
    addstr(title);

    long p = lineStart(top);
    int row = 0;
    while (row < rows && p <= tlen) {
        move(1 + row, 0);
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

    move(LINES - 2, 0);
    addstr("^O Write Out    ^X Exit    arrows Move");

    char status[160];
    snprintf(status, sizeof(status), "                        [ line %d/%d, col %d ]",
             line + 1, totalLines(), col + 1);
    move(LINES - 1, 0);
    addstr(status);

    move(1 + (line - top), col);
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
        if (c == 0x18) { /* ^X exit */
            break;
        } else if (c == 0x0f || c == 0x13) { /* ^O / ^S write out */
            save();
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
