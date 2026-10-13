// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The loader prompt.
//
// The counterpart of FreeBSD's stand/common/interp.c and the commands in
// stand/common/commands.c and boot.c: the "OK" prompt and the commands a user
// needs to inspect and steer a boot:
//
//   boot [-sv] [kernel]   boot (single user / verbose), optionally another kernel
//   autoboot [seconds]    count down, then boot
//   set name=value        set a loader variable
//   unset name            remove one
//   show [name]           show the variables, or one
//   ls [path]             list a directory on the boot volume
//   echo text...          print text
//   menu                  back to the boot menu
//   reboot                reset the machine
//   help, ?               list the commands

const platform: type = @import("platform");
const env: type = @import("env.zig");
const menu: type = @import("menu.zig");

/// What the prompt decided.
pub const Action: type = enum { boot, menu };

const LINE_MAX: usize = 160;

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Read a line with echo and backspace editing.
fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (true) {
        switch (platform.waitKey()) {
            .enter => {
                platform.print("\n");
                return buf[0..n];
            },
            .backspace => if (n > 0) {
                n -= 1;
                platform.print("\x08 \x08");
            },
            .char => |c| if (n < buf.len) {
                buf[n] = c;
                n += 1;
                platform.print(buf[n - 1 .. n]);
            },
            else => {},
        }
    }
}

/// The boot countdown of FreeBSD's autoboot(): any key cancels it.
/// Returns true when the timer ran out (or Enter was pressed).
pub fn autoboot(seconds: u64) bool {
    var pbuf: [128]u8 = undefined;
    const path: []const u8 = menu.kernelPath(&pbuf, env.get("kernel") orelse "kernel") orelse "kernel";
    platform.print("\nHit [Enter] to boot immediately, or any other key for command prompt.\n");
    var left: u64 = seconds;
    while (left > 0) : (left -= 1) {
        platform.printf("\rBooting [{s}] in {d} second{s}... ", .{ path, left, if (left == 1) "" else "s" });
        var ticks: usize = 0;
        while (ticks < 20) : (ticks += 1) {
            if (platform.getKey()) |key| {
                platform.print("\n");
                return key == .enter;
            }
            platform.delay(50_000);
        }
    }
    platform.printf("\rBooting [{s}]...               \n", .{path});
    return true;
}

fn help() void {
    platform.print(
        \\Available commands:
        \\  boot [-sv] [kernel]   boot the kernel (-s single user, -v verbose)
        \\  autoboot [seconds]    boot after a countdown
        \\  set name=value        set a loader variable
        \\  unset name            remove a loader variable
        \\  show [name]           show the loader variables
        \\  ls [path]             list a directory on the boot volume
        \\  echo [text]           print text
        \\  menu                  return to the boot menu
        \\  reboot                reboot the system
        \\
    );
}

/// Run the prompt until a command boots or returns to the menu.
pub fn run() Action {
    platform.print("\nType '?' for a list of commands, 'help' for more detailed help.\n");
    var buf: [LINE_MAX]u8 = undefined;
    while (true) {
        platform.print("OK ");
        const line: []const u8 = readLine(&buf);
        var t = menu.Tokens{ .s = line };
        const cmd: []const u8 = t.next() orelse continue;

        if (eql(cmd, "boot")) {
            env.unset("boot_single");
            while (t.next()) |arg| {
                if (arg.len > 1 and arg[0] == '-') {
                    for (arg[1..]) |c| switch (c) {
                        's' => _ = env.set("boot_single", "YES"),
                        'v' => _ = env.set("boot_verbose", "YES"),
                        else => platform.printf("boot: unknown flag -{c}\n", .{c}),
                    };
                } else {
                    _ = env.set("kernel", arg);
                }
            }
            return .boot;
        } else if (eql(cmd, "autoboot")) {
            const secs: u64 = if (t.next()) |a| parseNum(a) orelse 10 else 10;
            if (autoboot(secs)) return .boot;
        } else if (eql(cmd, "set")) {
            const arg: []const u8 = line[t.i..];
            if (!env.assign(arg)) platform.print("set: syntax is name=value\n");
        } else if (eql(cmd, "unset")) {
            while (t.next()) |name| env.unset(name);
        } else if (eql(cmd, "show")) {
            if (t.next()) |name| {
                if (env.get(name)) |v| {
                    platform.printf("{s}\n", .{v});
                } else {
                    platform.printf("{s} not set\n", .{name});
                }
            } else {
                env.show();
            }
        } else if (eql(cmd, "ls")) {
            const path: []const u8 = t.next() orelse "/";
            if (!platform.listDir(path)) platform.printf("ls: {s}: not found\n", .{path});
        } else if (eql(cmd, "echo")) {
            platform.printf("{s}\n", .{line[t.i..]});
        } else if (eql(cmd, "menu")) {
            return .menu;
        } else if (eql(cmd, "reboot")) {
            platform.reboot();
        } else if (eql(cmd, "help") or eql(cmd, "?")) {
            help();
        } else {
            platform.printf("{s}: command not found\n", .{cmd});
        }
    }
}

fn parseNum(s: []const u8) ?u64 {
    var n: u64 = 0;
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return n;
}
