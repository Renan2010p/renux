// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The boot menu.
//
// The counterpart of FreeBSD's stand/lua/menu.lua and drawer.lua: the brand,
// the logo, a frame titled "Welcome to Renux" with the numbered entries, the
// "Boot Options" submenu and the autoboot countdown, laid out at the same
// positions FreeBSD uses. Every entry does what it says:
//
//   1. Boot Multi user [Enter]   boot normally
//   2. Boot Single user          boot with -s (init offers a shell)
//   3. Escape to loader prompt   the OK prompt (interp.zig)
//   4. Reboot
//   5. Cons: ...                 which consoles the kernel attaches
//   6. Kernel: ...               cycles through the `kernels` that exist
//   7. Boot Options              single user and verbose toggles
//
// Each entry is chosen by its number or by its highlighted letter.
//
// Settings live in the loader environment (env.zig) under FreeBSD's names
// (boot_single, boot_verbose, console, kernel, kernels, autoboot_delay), so
// loader.conf and the `set` command reach the same knobs.

const std: type = @import("std");
const platform: type = @import("platform");
const env: type = @import("env.zig");
const gfx: type = @import("gfx_renux.zig");

/// What the menu decided.
pub const Action: type = enum { boot, prompt };

// Layout, as FreeBSD's drawer.lua: the menu text at (5, 10), the frame three
// columns left of it and one row above, 42 x 13 cells.
const MENU_X: usize = 5;
const MENU_Y: usize = 10;
const FRAME_X: usize = MENU_X - 3;
const FRAME_Y: usize = MENU_Y - 1;
const FRAME_W: usize = 42;
const FRAME_H: usize = 13;
/// Where the autoboot countdown is shown, below the frame.
const AUTOBOOT_X: usize = 4;
const AUTOBOOT_Y: usize = 23;
const AUTOBOOT_WIDTH: usize = 45;

/// The countdown checks for a key this many times per second.
const COUNTDOWN_TICKS_PER_SECOND: usize = 20;
const COUNTDOWN_TICK_US: usize = 1_000_000 / COUNTDOWN_TICKS_PER_SECOND;

/// The default autoboot delay, in seconds.
const DEFAULT_AUTOBOOT_DELAY: u64 = 10;

/// Whether the menu is drawn in colour (loader_color="NO" turns it off).
var color: bool = true;

// -- drawing -----------------------------------------------------------------

/// Print `text`, highlighting marked characters as FreeBSD's
/// color.highlight() does: `^x` highlights the single character x, `{...}`
/// a whole group.
fn printMarked(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '^' and i + 1 < text.len) {
            printHighlighted(text[i + 1 .. i + 2]);
            i += 2;
        } else if (text[i] == '{') {
            const end: usize = std.mem.indexOfScalarPos(u8, text, i, '}') orelse text.len;
            printHighlighted(text[i + 1 .. end]);
            i = end + 1;
        } else {
            const end: usize = std.mem.indexOfAnyPos(u8, text, i, "^{") orelse text.len;
            platform.print(text[i..end]);
            i = end;
        }
    }
}

/// Print `text` in bright white (when the menu has colour).
fn printHighlighted(text: []const u8) void {
    if (color) platform.setColor(.white, true);
    platform.print(text);
    if (color) platform.resetColor();
}

/// Print `piece` `count` times.
fn repeat(piece: []const u8, count: usize) void {
    for (0..count) |_| platform.print(piece);
}

/// Draw the frame around the menu, with `title` centred in its top border.
fn drawFrame(title: []const u8) void {
    const inner: usize = FRAME_W - 2;
    const title_len: usize = @min(title.len, inner);
    const left: usize = (inner - title_len) / 2;

    platform.gotoxy(FRAME_X, FRAME_Y);
    platform.print("┌");
    repeat("─", left);
    platform.print(title[0..title_len]);
    repeat("─", inner - left - title_len);
    platform.print("┐");

    for (1..FRAME_H - 1) |row| {
        platform.gotoxy(FRAME_X, FRAME_Y + row);
        platform.print("│");
        platform.gotoxy(FRAME_X + FRAME_W - 1, FRAME_Y + row);
        platform.print("│");
    }

    platform.gotoxy(FRAME_X, FRAME_Y + FRAME_H - 1);
    platform.print("└");
    repeat("─", inner);
    platform.print("┘");
}

/// Blank the inside of the frame.
fn clearInside() void {
    for (1..FRAME_H - 1) |row| {
        platform.gotoxy(FRAME_X + 1, FRAME_Y + row);
        repeat(" ", FRAME_W - 2);
    }
}

/// Print menu line `row` (counted from the top of the menu text).
fn line(row: usize, text: []const u8) void {
    platform.gotoxy(MENU_X, MENU_Y + row);
    printMarked(text);
}

// -- console and kernel choices ----------------------------------------------

/// The `console` values entry 5 cycles through, and how it names each one.
const consoles: []const []const u8 = &.{ "vidconsole comconsole", "vidconsole", "comconsole" };
const console_names: []const []const u8 = &.{ "Dual (Video primary)", "Video", "Serial" };

/// The position of the current `console` value in `consoles`.
fn consoleIndex() usize {
    const current: []const u8 = env.get("console") orelse return 0;
    for (consoles, 0..) |c, i| {
        if (std.mem.eql(u8, c, current)) return i;
    }
    return 0;
}

const MAX_KERNELS: usize = 8;
/// The entries of `kernels` that exist on the boot volume. The slices point
/// into the environment's copy of `kernels`.
var kernel_names: [MAX_KERNELS][]const u8 = undefined;
var kernel_count: usize = 0;

/// Collect the entries of `kernels` that exist as /boot/<name>/<bootfile>.
fn scanKernels() void {
    kernel_count = 0;
    const list: []const u8 = env.get("kernels") orelse "kernel";
    var names: std.mem.TokenIterator(u8, .any) = std.mem.tokenizeAny(u8, list, " \t");
    while (names.next()) |name| {
        if (kernel_count == MAX_KERNELS) break;
        var path_buf: [128]u8 = undefined;
        const path: []const u8 = kernelPath(&path_buf, name) orelse continue;
        if (platform.fileSize(path) != null) {
            kernel_names[kernel_count] = name;
            kernel_count += 1;
        }
    }
}

/// "/boot/<dir>/<bootfile>" for kernel directory `dir`, written into `buf`.
/// Returns null when it does not fit.
pub fn kernelPath(buf: []u8, dir: []const u8) ?[]const u8 {
    const file: []const u8 = env.get("bootfile") orelse "kernel";
    return std.fmt.bufPrint(buf, "/boot/{s}/{s}", .{ dir, file }) catch null;
}

/// The position of the current `kernel` value among the kernels found.
fn kernelIndex() usize {
    const current: []const u8 = env.get("kernel") orelse "kernel";
    for (kernel_names[0..kernel_count], 0..) |name, i| {
        if (std.mem.eql(u8, name, current)) return i;
    }
    return 0;
}

// -- the menus ---------------------------------------------------------------

/// "{On}" (highlighted) or "off", for a yes/no variable.
fn onOff(name: []const u8) []const u8 {
    return if (env.isYes(name)) "{On}" else "off";
}

/// Format into `buf`; an overlong result is cut to nothing.
fn format(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
}

fn drawMain() void {
    clearInside();
    var buf: [96]u8 = undefined;
    line(1, "1. ^Boot ^Multi user {[Enter]}");
    line(2, "2. Boot ^Single user");
    line(3, "3. ^Escape to loader prompt");
    line(4, "4. ^Reboot");
    line(5, format(&buf, "5. ^Cons: {s}", .{console_names[consoleIndex()]}));
    line(7, "Options:");
    const index: usize = kernelIndex();
    const kernel: []const u8 = if (kernel_count > 0) kernel_names[index] else "kernel";
    const default_mark: []const u8 = if (index == 0) "default/" else "";
    line(8, format(&buf, "6. ^Kernel: {s}{s} ({d} of {d})", .{ default_mark, kernel, index + 1, @max(kernel_count, 1) }));
    line(9, "7. Boot ^Options");
}

fn drawOptions() void {
    clearInside();
    var buf: [96]u8 = undefined;
    line(1, "1. Back to main menu {[Backspace]}");
    line(2, "2. ^Load System Defaults");
    line(4, "Boot Options:");
    line(5, format(&buf, "3. ^Single user. : {s}", .{onOff("boot_single")}));
    line(6, format(&buf, "4. ^Verbose..... : {s}", .{onOff("boot_verbose")}));
}

/// Flip a yes/no variable.
fn toggle(name: []const u8) void {
    if (env.isYes(name)) env.unset(name) else _ = env.set(name, "YES");
}

/// Draw the whole screen: brand, logo and frame.
fn drawScreen() void {
    platform.clear();
    platform.cursor(false);
    gfx.drawBrand();
    gfx.drawLogo(env.get("loader_logo") orelse "renux", color);
    drawFrame(env.get("loader_menu_title") orelse "Welcome to Renux");
}

fn drawAutobootLine(seconds: u64) void {
    platform.gotoxy(AUTOBOOT_X, AUTOBOOT_Y);
    var buf: [80]u8 = undefined;
    printMarked(format(&buf, "Autoboot in {d} second{s}. {{[Space]}} to pause ", .{ seconds, if (seconds == 1) "" else "s" }));
}

fn clearAutobootLine() void {
    platform.gotoxy(AUTOBOOT_X, AUTOBOOT_Y);
    repeat(" ", AUTOBOOT_WIDTH);
}

/// The autoboot delay in seconds; 0 when autoboot is off
/// (autoboot_delay="NO" or "-1").
fn autobootDelay() u64 {
    const value: []const u8 = env.get("autoboot_delay") orelse return DEFAULT_AUTOBOOT_DELAY;
    if (std.mem.eql(u8, value, "NO") or std.mem.eql(u8, value, "-1")) return 0;
    return env.parseDecimal(value) orelse DEFAULT_AUTOBOOT_DELAY;
}

/// The result of the autoboot countdown.
const Countdown: type = union(enum) {
    /// The time ran out.
    expired,
    /// A key stopped it; a key other than Space also counts as a menu choice.
    stopped: ?platform.Key,
};

/// Count `seconds` down on screen, as FreeBSD's menu.autoboot() does.
fn countdown(seconds: u64) Countdown {
    var left: u64 = seconds;
    while (left > 0) : (left -= 1) {
        drawAutobootLine(left);
        for (0..COUNTDOWN_TICKS_PER_SECOND) |_| {
            if (platform.getKey()) |key| {
                clearAutobootLine();
                const is_space: bool = key == .char and key.char == ' ';
                return .{ .stopped = if (is_space) null else key };
            }
            platform.delay(COUNTDOWN_TICK_US);
        }
    }
    clearAutobootLine();
    return .expired;
}

/// Run the menu until the user (or the autoboot timer) picks an action.
pub fn run() Action {
    color = !std.mem.eql(u8, env.get("loader_color") orelse "", "NO");
    scanKernels();
    drawScreen();
    drawMain();

    var pending: ?platform.Key = null;
    const delay: u64 = autobootDelay();
    if (delay > 0) {
        switch (countdown(delay)) {
            .expired => {
                env.unset("boot_single");
                return .boot;
            },
            .stopped => |key| pending = key,
        }
    }

    var in_options: bool = false;
    while (true) {
        const key: platform.Key = pending orelse platform.waitKey();
        pending = null;
        const result: ?Action = if (in_options) optionsKey(key, &in_options) else mainKey(key, &in_options);
        if (result) |action| return action;
    }
}

/// Handle `key` in the main menu. Returns the action it chooses, if any.
fn mainKey(key: platform.Key, in_options: *bool) ?Action {
    switch (key) {
        .enter => {
            env.unset("boot_single");
            return .boot;
        },
        .escape => return .prompt,
        .char => |c| switch (std.ascii.toLower(c)) {
            '1', 'b' => {
                env.unset("boot_single");
                return .boot;
            },
            '2', 's' => {
                _ = env.set("boot_single", "YES");
                return .boot;
            },
            '3', 'e' => return .prompt,
            '4', 'r' => platform.reboot(),
            '5', 'c' => {
                _ = env.set("console", consoles[(consoleIndex() + 1) % consoles.len]);
                drawMain();
            },
            '6', 'k' => {
                if (kernel_count > 1) {
                    _ = env.set("kernel", kernel_names[(kernelIndex() + 1) % kernel_count]);
                }
                drawMain();
            },
            '7', 'o' => {
                in_options.* = true;
                drawOptions();
            },
            else => {},
        },
        else => {},
    }
    return null;
}

/// Handle `key` in the Boot Options submenu. It never chooses an action.
fn optionsKey(key: platform.Key, in_options: *bool) ?Action {
    switch (key) {
        .backspace => {
            in_options.* = false;
            drawMain();
        },
        .char => |c| switch (std.ascii.toLower(c)) {
            '1' => {
                in_options.* = false;
                drawMain();
            },
            '2', 'l' => {
                env.unset("boot_single");
                env.unset("boot_verbose");
                drawOptions();
            },
            '3', 's' => {
                toggle("boot_single");
                drawOptions();
            },
            '4', 'v' => {
                toggle("boot_verbose");
                drawOptions();
            },
            else => {},
        },
        else => {},
    }
    return null;
}

/// Leave the menu screen: clear it and restore the cursor.
pub fn finish() void {
    platform.resetColor();
    platform.clear();
    platform.cursor(true);
}
