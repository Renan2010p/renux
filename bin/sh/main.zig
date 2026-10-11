// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin/sh: the ZenBSD command shell.
//
// A first shell: it reads lines from the console, echoes them, and runs a few
// built-in commands. There is no process creation yet, so external commands
// cannot be executed; that arrives with fork/exec.

const libc: type = @import("libc");
const printf = libc.stdio.printf;
const puts = libc.stdio.puts;
const putchar = libc.stdio.putchar;
const getchar = libc.stdio.getchar;

const MAX_LINE: usize = 256;

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') {
        start += 1;
    }
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') {
        end -= 1;
    }
    return s[start..end];
}

/// Read one line, echoing and handling backspace.
fn readLine(buf: []u8) usize {
    var len: usize = 0;
    while (true) {
        const c: u8 = getchar();
        if (c == '\r' or c == '\n') {
            putchar('\n');
            return len;
        }
        if (c == 0x7f or c == 0x08) { // backspace / delete
            if (len > 0) {
                len -= 1;
                printf("\x08 \x08", .{});
            }
            continue;
        }
        if (c < 0x20 or c >= 0x7f) {
            continue; // ignore other control characters
        }
        if (len < buf.len) {
            buf[len] = c;
            len += 1;
            putchar(c);
        }
    }
}

/// Run one command line.
fn execute(line: []const u8) void {
    const cmd: []const u8 = trim(line);
    if (cmd.len == 0) {
        return;
    }

    var i: usize = 0;
    while (i < cmd.len and cmd[i] != ' ') : (i += 1) {}
    const name: []const u8 = cmd[0..i];
    const rest: []const u8 = if (i < cmd.len) trim(cmd[i..]) else "";

    if (equal(name, "help")) {
        puts("builtins: help echo uname exit");
    } else if (equal(name, "echo")) {
        puts(rest);
    } else if (equal(name, "uname")) {
        puts("ZenBSD 0.1 amd64");
    } else if (equal(name, "exit")) {
        libc.syscall.exit(0);
    } else {
        printf("sh: %s: not found\n", .{name});
    }
}

export fn _start() callconv(.c) noreturn {
    puts("ZenBSD sh -- type 'help'");

    var buf: [MAX_LINE]u8 = undefined;
    while (true) {
        printf("zenbsd> ", .{});
        const n: usize = readLine(&buf);
        execute(buf[0..n]);
    }
}
