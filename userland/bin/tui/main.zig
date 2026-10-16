// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/tui: a full-screen demonstration of Renux's minimal curses.
//
// It clears the terminal, draws two lines and waits for the x key, then
// restores the terminal.

const libc: type = @import("libc");
const curses: type = libc.curses;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = argc;
    _ = argv;
    _ = envp;
    _ = curses.initscr();
    defer _ = curses.endwin();
    _ = curses.noecho();
    _ = curses.keypad(curses.stdscr, 1);

    _ = curses.clear();
    _ = curses.mvaddstr(3, 5, "Renux curses demo");
    _ = curses.mvaddstr(5, 5, "Press x to exit.");
    _ = curses.refresh();

    while (true) {
        const key: c_int = curses.getch();
        if (key == 'x' or key == curses.ERR) break;
    }
    return 0;
}
