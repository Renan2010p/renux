// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// /bin/sh: the ZenBSD command shell.
//
// A small shell in the spirit of the BSD sh: a prompt, line editing, a few
// built-ins, and external commands run with fork + execve + wait.

const libc: type = @import("libc");
const printf = libc.stdio.printf;
const puts = libc.stdio.puts;
const putchar = libc.stdio.putchar;
const getchar = libc.stdio.getchar;

const MAX_LINE: usize = 256;
const MAX_NAME: usize = 128;

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

fn readLine(buf: []u8) usize {
    var len: usize = 0;
    while (true) {
        const c: u8 = getchar();
        if (c == '\r' or c == '\n') {
            putchar('\n');
            return len;
        }
        if (c == 0x7f or c == 0x08) {
            if (len > 0) {
                len -= 1;
                printf("\x08 \x08", .{});
            }
            continue;
        }
        if (c < 0x20 or c >= 0x7f) {
            continue;
        }
        if (len < buf.len) {
            buf[len] = c;
            len += 1;
            putchar(c);
        }
    }
}

/// Run `name` as an external program via fork + execve + wait.
fn runExternal(name: []const u8) void {
    if (name.len + 1 > MAX_NAME) {
        puts("sh: command name too long");
        return;
    }

    var path: [MAX_NAME]u8 = undefined;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        path[i] = name[i];
    }
    path[name.len] = 0;

    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        _ = libc.syscall.execve(@ptrCast(&path));
        printf("sh: %s: not found\n", .{name});
        libc.syscall.exit(127);
    } else if (pid > 0) {
        _ = libc.syscall.wait(null);
    } else {
        puts("sh: fork failed");
    }
}

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
        puts("builtins: help echo uname getpid exit");
        puts("external commands are loaded from the boot modules");
    } else if (equal(name, "echo")) {
        puts(rest);
    } else if (equal(name, "uname")) {
        puts("ZenBSD 0.1 amd64");
    } else if (equal(name, "getpid")) {
        printf("pid %d\n", .{libc.syscall.getpid()});
    } else if (equal(name, "exit")) {
        libc.syscall.exit(0);
    } else {
        runExternal(name);
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
