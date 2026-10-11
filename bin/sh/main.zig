// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// /bin/sh: the Renux command shell.
//
// A small shell in the spirit of the BSD sh: a prompt, line editing, a few
// built-ins, and external commands run with fork + execve + wait.

const libc: type = @import("libc");
const printf = libc.stdio.printf;
const puts = libc.stdio.puts;
const putchar = libc.stdio.putchar;
const getchar = libc.stdio.getchar;

comptime {
    // The C startup provides _start (the ELF entry point) and calls main().
    _ = @import("csu").crt0;
}

const MAX_LINE: usize = 256;
const MAX_NAME: usize = 128;
const MAX_PATH: usize = 256;
const MAX_ARGS: usize = 8;

/// Copy `s` into `buf` and NUL-terminate it, returning the C string.
fn cstr(s: []const u8, buf: []u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) {
        return null;
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        buf[i] = s[i];
    }
    buf[s.len] = 0;
    return @ptrCast(&buf[0]);
}

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
            return len;
        }
        if (c == 0x7f or c == 0x08) {
            if (len > 0) {
                len -= 1;
            }
            continue;
        }
        if (c < 0x20 or c >= 0x7f) {
            continue;
        }
        if (len < buf.len) {
            buf[len] = c;
            len += 1;
        }
    }
}

/// Run `name` with arguments `rest` as an external program found in /bin or
/// /usr/bin, via fork + execve + wait. Arguments are split on spaces.
fn runExternal(name: []const u8, rest: []const u8) void {
    if (name.len + 1 > MAX_NAME) {
        puts("sh: command name too long");
        return;
    }

    var store: [MAX_LINE]u8 = undefined;
    var av: [MAX_ARGS + 1]?[*:0]const u8 = undefined;
    var argc: usize = 0;

    // argv[0] is a NUL-terminated copy of the command name.
    var nbuf: [MAX_NAME]u8 = undefined;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        nbuf[i] = name[i];
    }
    nbuf[name.len] = 0;
    av[argc] = @ptrCast(&nbuf[0]);
    argc += 1;

    // Split the argument text into NUL-terminated words.
    var ai: usize = 0;
    var aj: usize = 0;
    while (ai < rest.len and argc < MAX_ARGS) {
        while (ai < rest.len and rest[ai] == ' ') : (ai += 1) {}
        if (ai >= rest.len) {
            break;
        }
        const start: usize = aj;
        while (ai < rest.len and rest[ai] != ' ') {
            store[aj] = rest[ai];
            aj += 1;
            ai += 1;
        }
        store[aj] = 0;
        aj += 1;
        av[argc] = @ptrCast(&store[start]);
        argc += 1;
    }
    av[argc] = null;

    var ep: [1]?[*:0]const u8 = .{null};

    const pid: i32 = libc.syscall.fork();
    if (pid == 0) {
        tryExec("/bin", name, @ptrCast(&av), @ptrCast(&ep));
        tryExec("/usr/bin", name, @ptrCast(&av), @ptrCast(&ep));
        printf("sh: %s: not found\n", .{name});
        libc.syscall.exit(127);
    } else if (pid > 0) {
        _ = libc.syscall.wait(null);
    } else {
        puts("sh: fork failed");
    }
}

/// execve `dir/name`; returns only on failure.
fn tryExec(dir: []const u8, name: []const u8, av: [*]?[*:0]const u8, ep: [*]?[*:0]const u8) void {
    if (dir.len + 1 + name.len + 1 > MAX_PATH) {
        return;
    }
    var pb: [MAX_PATH]u8 = undefined;
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        pb[i] = dir[i];
    }
    pb[i] = '/';
    i += 1;
    var j: usize = 0;
    while (j < name.len) : (j += 1) {
        pb[i + j] = name[j];
    }
    pb[i + name.len] = 0;
    _ = libc.syscall.execve(@ptrCast(&pb[0]), av, ep);
}

fn execute(line: []const u8) void {
    const cmd: []const u8 = trim(line);
    if (cmd.len == 0) {
        return;
    }
    if (cmd[0] == '#') {
        return; // comment
    }

    var i: usize = 0;
    while (i < cmd.len and cmd[i] != ' ') : (i += 1) {}
    const name: []const u8 = cmd[0..i];
    const rest: []const u8 = if (i < cmd.len) trim(cmd[i..]) else "";

    if (equal(name, "help")) {
        puts("builtins: help echo uname getpid cd exit");
        puts("external commands are loaded from /bin");
    } else if (equal(name, "echo")) {
        puts(rest);
    } else if (equal(name, "uname")) {
        puts("Renux 0.1 amd64");
    } else if (equal(name, "getpid")) {
        printf("pid %d\n", .{libc.syscall.getpid()});
    } else if (equal(name, "cd")) {
        if (rest.len == 0) {
            puts("cd: missing operand");
        } else {
            var pb: [MAX_PATH]u8 = undefined;
            const cpath: [*:0]const u8 = cstr(rest, &pb) orelse {
                puts("cd: path too long");
                return;
            };
            if (libc.syscall.chdir(cpath) < 0) {
                printf("cd: %s: no such directory\n", .{rest});
            }
        }
    } else if (equal(name, "exit")) {
        libc.syscall.exit(0);
    } else {
        runExternal(name, rest);
    }
}

/// A NUL-terminated string as a slice.
fn zspan(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

/// Run a shell script from `path`, one command per line, then return.
fn runScript(path: [*:0]const u8) void {
    const fd: i64 = libc.syscall.open(path, 0, 0);
    if (fd < 0) {
        printf("sh: %s: cannot open\n", .{zspan(path)});
        return;
    }

    var buf: [512]u8 = undefined;
    var line: [MAX_LINE]u8 = undefined;
    var linelen: usize = 0;
    while (true) {
        const n: u64 = libc.syscall.read(@intCast(fd), &buf);
        if (n == 0 or n > buf.len) {
            break;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const c: u8 = buf[k];
            if (c == '\n') {
                execute(line[0..linelen]);
                linelen = 0;
            } else if (c != '\r' and linelen < line.len) {
                line[linelen] = c;
                linelen += 1;
            }
        }
    }
    if (linelen > 0) {
        execute(line[0..linelen]);
    }
    _ = libc.syscall.close(@intCast(fd));
}

/// Append `s` to `buf` at index `n`.
fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |c| {
        if (n.* < buf.len) {
            buf[n.*] = c;
            n.* += 1;
        }
    }
}

/// Build the shell prompt: $PS1 if set (with a few escapes), else the FreeBSD
/// default "# " for root and "$ " for a user.
fn buildPrompt(buf: []u8) []const u8 {
    const uid: u32 = libc.syscall.getuidRaw();
    var n: usize = 0;

    const ps1 = libc.c.getenv("PS1");
    if (ps1) |p| {
        var i: usize = 0;
        while (p[i] != 0) : (i += 1) {
            if (p[i] != '\\' or p[i + 1] == 0) {
                if (n < buf.len) {
                    buf[n] = p[i];
                    n += 1;
                }
                continue;
            }
            i += 1;
            switch (p[i]) {
                'u' => appendStr(buf, &n, if (uid == 0) "root" else "user"),
                'h' => appendStr(buf, &n, "renux"),
                '$' => appendStr(buf, &n, if (uid == 0) "#" else "$"),
                'w' => {
                    var cw: [256]u8 = undefined;
                    if (libc.syscall.getcwd(&cw) == 0) {
                        var k: usize = 0;
                        while (cw[k] != 0) : (k += 1) {}
                        appendStr(buf, &n, cw[0..k]);
                    }
                },
                'n' => appendStr(buf, &n, "\n"),
                '\\' => appendStr(buf, &n, "\\"),
                else => {
                    if (n < buf.len) {
                        buf[n] = p[i];
                        n += 1;
                    }
                },
            }
        }
        return buf[0..n];
    }

    appendStr(buf, &n, if (uid == 0) "# " else "$ ");
    return buf[0..n];
}

export fn main(argc: i32, argv: [*]?[*:0]const u8, envp: [*]?[*:0]const u8) callconv(.c) i32 {
    _ = envp;

    // "sh script": run the script and exit.
    if (argc >= 2) {
        if (argv[1]) |path| {
            runScript(path);
            return 0;
        }
    }

    // An interactive shell ignores SIGINT while reading commands.
    _ = libc.syscall.signal(libc.syscall.SIGINT, libc.syscall.SIG_IGN);

    puts("Renux sh -- type 'help'");
    var buf: [MAX_LINE]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    while (true) {
        _ = libc.syscall.write(1, buildPrompt(&pbuf));
        const n: usize = readLine(&buf);
        execute(buf[0..n]);
    }
}
