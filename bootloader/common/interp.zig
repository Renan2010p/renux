// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The loader prompt.
//
// The counterpart of FreeBSD's stand/common/interp.c and the commands in
// stand/common/commands.c and boot.c: the "OK" prompt and the commands a
// user needs to inspect and steer a boot. The `commands` table below is the
// single list of them; `help` prints it.

const std: type = @import("std");
const platform: type = @import("platform");
const env: type = @import("env.zig");
const menu: type = @import("menu.zig");

/// What the prompt decided.
pub const Action: type = enum { boot, menu };

/// Longest command line the prompt accepts.
const LINE_MAX: usize = 160;

/// The default `autoboot` countdown, in seconds.
const DEFAULT_AUTOBOOT_SECONDS: u64 = 10;

/// The countdown checks for a key this many times per second.
const COUNTDOWN_TICKS_PER_SECOND: usize = 20;
const COUNTDOWN_TICK_US: usize = 1_000_000 / COUNTDOWN_TICKS_PER_SECOND;

/// The words of a command line.
const Words: type = std.mem.TokenIterator(u8, .any);

/// A command: its name, its usage and summary for `help`, and what it does.
/// `run` gets the words after the command name; it returns an action when
/// the command leaves the prompt.
const Command: type = struct {
    name: []const u8,
    usage: []const u8,
    summary: []const u8,
    run: *const fn (args: *Words) ?Action,
};

const commands: []const Command = &.{
    .{ .name = "boot", .usage = "boot [-sv] [kernel]", .summary = "boot the kernel (-s single user, -v verbose)", .run = cmdBoot },
    .{ .name = "autoboot", .usage = "autoboot [seconds]", .summary = "boot after a countdown", .run = cmdAutoboot },
    .{ .name = "set", .usage = "set name=value", .summary = "set a loader variable", .run = cmdSet },
    .{ .name = "unset", .usage = "unset name", .summary = "remove a loader variable", .run = cmdUnset },
    .{ .name = "show", .usage = "show [name]", .summary = "show the loader variables", .run = cmdShow },
    .{ .name = "ls", .usage = "ls [path]", .summary = "list a directory on the boot volume", .run = cmdLs },
    .{ .name = "echo", .usage = "echo [text]", .summary = "print text", .run = cmdEcho },
    .{ .name = "menu", .usage = "menu", .summary = "return to the boot menu", .run = cmdMenu },
    .{ .name = "reboot", .usage = "reboot", .summary = "reboot the system", .run = cmdReboot },
    .{ .name = "help", .usage = "help, ?", .summary = "list the commands", .run = cmdHelp },
};

/// Run the prompt until a command boots or returns to the menu.
pub fn run() Action {
    platform.print("\nType '?' for a list of commands, 'help' for more detailed help.\n");
    var buf: [LINE_MAX]u8 = undefined;
    while (true) {
        platform.print("OK ");
        const line: []const u8 = readLine(&buf);
        var words: Words = std.mem.tokenizeAny(u8, line, " \t");
        const name: []const u8 = words.next() orelse continue;
        const command: *const Command = lookup(name) orelse {
            platform.printf("{s}: command not found\n", .{name});
            continue;
        };
        if (command.run(&words)) |action| return action;
    }
}

/// The command called `name` ("?" is `help`).
fn lookup(name: []const u8) ?*const Command {
    const wanted: []const u8 = if (std.mem.eql(u8, name, "?")) "help" else name;
    for (commands) |*command| {
        if (std.mem.eql(u8, command.name, wanted)) return command;
    }
    return null;
}

/// Read a line with echo and backspace editing.
fn readLine(buf: []u8) []const u8 {
    var len: usize = 0;
    while (true) {
        switch (platform.waitKey()) {
            .enter => {
                platform.print("\n");
                return buf[0..len];
            },
            .backspace => if (len > 0) {
                len -= 1;
                platform.print("\x08 \x08");
            },
            .char => |c| if (len < buf.len) {
                buf[len] = c;
                len += 1;
                platform.print(buf[len - 1 .. len]);
            },
            else => {},
        }
    }
}

/// The boot countdown of FreeBSD's autoboot(): any key cancels it.
/// Returns true when the time ran out or Enter was pressed.
pub fn autoboot(seconds: u64) bool {
    var path_buf: [128]u8 = undefined;
    const path: []const u8 = menu.kernelPath(&path_buf, env.get("kernel") orelse "kernel") orelse "kernel";
    platform.print("\nHit [Enter] to boot immediately, or any other key for command prompt.\n");
    var left: u64 = seconds;
    while (left > 0) : (left -= 1) {
        platform.printf("\rBooting [{s}] in {d} second{s}... ", .{ path, left, if (left == 1) "" else "s" });
        for (0..COUNTDOWN_TICKS_PER_SECOND) |_| {
            if (platform.getKey()) |key| {
                platform.print("\n");
                return key == .enter;
            }
            platform.delay(COUNTDOWN_TICK_US);
        }
    }
    platform.printf("\rBooting [{s}]...               \n", .{path});
    return true;
}

// -- the commands ------------------------------------------------------------

/// boot [-sv] [kernel]
fn cmdBoot(args: *Words) ?Action {
    env.unset("boot_single");
    while (args.next()) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| switch (flag) {
                's' => _ = env.set("boot_single", "YES"),
                'v' => _ = env.set("boot_verbose", "YES"),
                else => platform.printf("boot: unknown flag -{c}\n", .{flag}),
            };
        } else {
            _ = env.set("kernel", arg);
        }
    }
    return .boot;
}

/// autoboot [seconds]
fn cmdAutoboot(args: *Words) ?Action {
    const seconds: u64 = if (args.next()) |arg| env.parseDecimal(arg) orelse DEFAULT_AUTOBOOT_SECONDS else DEFAULT_AUTOBOOT_SECONDS;
    return if (autoboot(seconds)) .boot else null;
}

/// set name=value (the rest of the line, so a quoted value may hold spaces)
fn cmdSet(args: *Words) ?Action {
    if (!env.assign(args.rest())) platform.print("set: syntax is name=value\n");
    return null;
}

/// unset name...
fn cmdUnset(args: *Words) ?Action {
    while (args.next()) |name| env.unset(name);
    return null;
}

/// show [name]
fn cmdShow(args: *Words) ?Action {
    const name: []const u8 = args.next() orelse {
        env.show();
        return null;
    };
    if (env.get(name)) |value| {
        platform.printf("{s}\n", .{value});
    } else {
        platform.printf("{s} not set\n", .{name});
    }
    return null;
}

/// ls [path]
fn cmdLs(args: *Words) ?Action {
    const path: []const u8 = args.next() orelse "/";
    if (!platform.listDir(path)) platform.printf("ls: {s}: not found\n", .{path});
    return null;
}

/// echo [text]
fn cmdEcho(args: *Words) ?Action {
    platform.printf("{s}\n", .{args.rest()});
    return null;
}

/// menu
fn cmdMenu(_: *Words) ?Action {
    return .menu;
}

/// reboot
fn cmdReboot(_: *Words) ?Action {
    platform.reboot();
}

/// help, ?
fn cmdHelp(_: *Words) ?Action {
    platform.print("Available commands:\n");
    for (commands) |command| {
        platform.printf("  {s:<22}{s}\n", .{ command.usage, command.summary });
    }
    return null;
}
