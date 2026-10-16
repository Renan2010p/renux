// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// /bin/nano (also installed as /bin/edit): a small full-screen editor.
//
// A minimal editor with GNU nano's layout, built on Renux's minimal curses,
// for systems without the FreeBSD packages (when GNU nano is installed, it
// replaces this one). The screen is:
//
//   line 0         the title: "Renux nano", a modified mark and the file name
//   lines 1..n-3   the text, scrolled to keep the cursor visible
//   line n-2       the key help
//   line n-1       the cursor position
//
// Keys:
//
//   arrows       move the cursor
//   ^O, ^S       write the file out
//   ^X           exit (without asking; unsaved changes are lost)
//   Backspace    delete the character before the cursor
//   Enter        split the line
//
// The whole file is held in one fixed buffer of MAX_TEXT bytes.

const std: type = @import("std");
const libc: type = @import("libc");
const curses: type = libc.curses;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

/// The largest file the editor holds.
const MAX_TEXT: usize = 64 * 1024;

/// Control keys, as the terminal sends them.
const CTRL_O: c_int = 0x0f;
const CTRL_S: c_int = 0x13;
const CTRL_X: c_int = 0x18;
const BACKSPACE: c_int = 0x08;
const DELETE: c_int = 0x7f;

/// Screen lines that are not text: the title, the help and the status.
const CHROME_LINES: c_int = 3;

/// Mode of a file the editor creates: rw-r--r--.
const NEW_FILE_MODE: u64 = 0o644;

/// A place in the text: line and column, from 0.
const Position: type = struct { line: usize, col: usize };

/// The text being edited.
const Buffer: type = struct {
    bytes: [MAX_TEXT]u8 = undefined,
    len: usize = 0,
    /// The cursor, as an offset into `bytes`.
    cursor: usize = 0,
    modified: bool = false,

    fn text(b: *const Buffer) []const u8 {
        return b.bytes[0..b.len];
    }

    /// Insert `c` at the cursor. Does nothing when the buffer is full.
    fn insert(b: *Buffer, c: u8) void {
        if (b.len == MAX_TEXT) return;
        std.mem.copyBackwards(u8, b.bytes[b.cursor + 1 .. b.len + 1], b.bytes[b.cursor..b.len]);
        b.bytes[b.cursor] = c;
        b.cursor += 1;
        b.len += 1;
        b.modified = true;
    }

    /// Delete the character before the cursor.
    fn backspace(b: *Buffer) void {
        if (b.cursor == 0) return;
        std.mem.copyForwards(u8, b.bytes[b.cursor - 1 .. b.len - 1], b.bytes[b.cursor..b.len]);
        b.cursor -= 1;
        b.len -= 1;
        b.modified = true;
    }

    /// The line and column of the cursor, from 0.
    fn cursorPosition(b: *const Buffer) Position {
        const before: []const u8 = b.bytes[0..b.cursor];
        const line_start: usize = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |nl| nl + 1 else 0;
        return .{ .line = std.mem.count(u8, before, "\n"), .col = b.cursor - line_start };
    }

    /// The number of lines (a text without newlines has one).
    fn lineCount(b: *const Buffer) usize {
        return std.mem.count(u8, b.text(), "\n") + 1;
    }

    /// The offset where line `line` starts (the end of the text when there
    /// are fewer lines).
    fn lineStart(b: *const Buffer, line: usize) usize {
        var offset: usize = 0;
        var current: usize = 0;
        while (offset < b.len and current < line) : (offset += 1) {
            if (b.bytes[offset] == '\n') current += 1;
        }
        return offset;
    }

    /// The offset of the newline that ends the line starting at `start`, or
    /// the end of the text.
    fn lineEnd(b: *const Buffer, start: usize) usize {
        return std.mem.indexOfScalarPos(u8, b.text(), start, '\n') orelse b.len;
    }

    /// Move the cursor `delta` lines up (negative) or down, keeping its
    /// column where the target line is long enough.
    fn moveVertical(b: *Buffer, delta: isize) void {
        const position: Position = b.cursorPosition();
        const target: usize = @intCast(@max(0, @as(isize, @intCast(position.line)) + delta));
        const start: usize = b.lineStart(target);
        b.cursor = @min(start + position.col, b.lineEnd(start));
    }
};

var buffer: Buffer = .{};
/// The file being edited, or null for a new, unnamed buffer.
var file_name: ?[*:0]const u8 = null;

/// Read `path` into the buffer. A missing file starts an empty buffer.
fn load(path: [*:0]const u8) void {
    const fd: i64 = libc.syscall.open(path, libc.syscall.O_RDONLY, 0);
    if (fd < 0) return;
    defer _ = libc.syscall.close(@intCast(fd));
    while (buffer.len < MAX_TEXT) {
        const n: u64 = libc.syscall.read(@intCast(fd), buffer.bytes[buffer.len..]);
        // read returns a negative errno as a huge unsigned value.
        if (n == 0 or n > MAX_TEXT - buffer.len) break;
        buffer.len += @intCast(n);
    }
}

/// Write the buffer to its file. Returns false when it cannot.
fn save() bool {
    const path: [*:0]const u8 = file_name orelse return false;
    const flags: u64 = libc.syscall.O_WRONLY | libc.syscall.O_CREAT | libc.syscall.O_TRUNC;
    const fd: i64 = libc.syscall.open(path, flags, NEW_FILE_MODE);
    if (fd < 0) return false;
    defer _ = libc.syscall.close(@intCast(fd));
    _ = libc.syscall.write(@intCast(fd), buffer.text());
    buffer.modified = false;
    return true;
}

/// Write `text` at screen line `y`, column `x`.
fn drawAt(y: c_int, x: c_int, text: []const u8) void {
    _ = curses.move(y, x);
    for (text) |c| _ = curses.addch(c);
}

/// Redraw the whole screen and place the cursor.
fn render() void {
    const position: Position = buffer.cursorPosition();
    const text_rows: usize = @intCast(@max(1, curses.LINES - CHROME_LINES));
    const top: usize = if (position.line >= text_rows) position.line - text_rows + 1 else 0;

    _ = curses.clear();

    var line_buf: [160]u8 = undefined;
    const name: []const u8 = if (file_name) |f| std.mem.span(f) else "[ New File ]";
    const title: []const u8 = std.fmt.bufPrint(&line_buf, "  Renux nano{s}     {s}", .{ if (buffer.modified) " " else "", name }) catch "";
    drawAt(0, 0, title);

    var start: usize = buffer.lineStart(top);
    for (0..text_rows) |row| {
        if (start > buffer.len) break;
        const end: usize = buffer.lineEnd(start);
        drawAt(@intCast(1 + row), 0, buffer.bytes[start..end]);
        if (end == buffer.len) break;
        start = end + 1;
    }

    drawAt(curses.LINES - 2, 0, "^O Write Out    ^X Exit    arrows Move");
    const status: []const u8 = std.fmt.bufPrint(&line_buf, "                        [ line {d}/{d}, col {d} ]", .{ position.line + 1, buffer.lineCount(), position.col + 1 }) catch "";
    drawAt(curses.LINES - 1, 0, status);

    _ = curses.move(@intCast(1 + position.line - top), @intCast(position.col));
    _ = curses.refresh();
}

/// Apply one key press. Returns false when the editor should exit.
fn handleKey(key: c_int) bool {
    switch (key) {
        CTRL_X => return false,
        CTRL_O, CTRL_S => _ = save(),
        curses.KEY_LEFT => buffer.cursor -|= 1,
        curses.KEY_RIGHT => buffer.cursor = @min(buffer.cursor + 1, buffer.len),
        curses.KEY_UP => buffer.moveVertical(-1),
        curses.KEY_DOWN => buffer.moveVertical(1),
        DELETE, BACKSPACE => buffer.backspace(),
        '\r', '\n' => buffer.insert('\n'),
        ' '...'~' => buffer.insert(@intCast(key)),
        else => {},
    }
    return true;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;
    if (argc > 1) {
        file_name = argv[1];
        load(argv[1].?);
    }

    _ = curses.initscr();
    defer _ = curses.endwin();
    _ = curses.noecho();
    _ = curses.keypad(curses.stdscr, 1);

    while (true) {
        render();
        const key: c_int = curses.getch();
        if (key == curses.ERR) continue;
        if (!handleKey(key)) break;
    }
    return 0;
}
