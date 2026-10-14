// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Loader platform services on UEFI.
//
// The machine-dependent half of the loader console and I/O, the counterpart of
// FreeBSD's stand/efi/libefi (efi_console.c, efipart.c, framebuffer.c):
//
//   - output: on a linear GOP framebuffer the loader draws its own text over
//     the whole screen (stand/common/gfx_fb.zig) and mirrors it to the serial
//     console (the firmware's Serial I/O protocol) with ANSI sequences, as
//     FreeBSD's loader does; without one it falls back to the firmware's
//     SimpleTextOutput;
//   - key input through SimpleTextInput (keyboard and serial);
//   - file access on the boot volume, delays and reset. The machine-independent loader
// (stand/common) reaches the firmware only through this module, imported as
// "platform".

const std: type = @import("std");
const uefi: type = std.os.uefi;
const Attr: type = uefi.protocol.SimpleTextOutput.Attribute;
const gfx: type = @import("gfx_fb");

/// The 8 text colours the loader menu uses (FreeBSD's color.lua).
pub const Color: type = enum { black, red, green, yellow, blue, magenta, cyan, white };

/// A key press.
pub const Key: type = union(enum) {
    char: u8,
    enter,
    backspace,
    escape,
    up,
    down,
    other,
};

var root_dir: ?*uefi.protocol.File = null;
var fg: Color = .white;
var bright: bool = false;
/// The loader draws on the framebuffer itself (else: firmware text console).
var use_gfx: bool = false;

// -- serial mirror (graphics mode) ---------------------------------------------
//
// The serial port is reached through the firmware's Serial I/O protocol, as
// FreeBSD's stand/efi/libefi/eficom.c does, not by programming a UART: the
// firmware knows where the console port is on every architecture.

var sio: ?*uefi.protocol.SerialIo = null;

/// Write bytes to the serial console, when the firmware has one.
fn serialWrite(s: []const u8) void {
    const port = sio orelse return;
    var off: usize = 0;
    while (off < s.len) {
        const n: usize = port.write(s[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

/// Choose the console: draw on the GOP framebuffer when it is a linear 32-bit
/// one, otherwise keep the firmware's text console.
pub fn consInit() void {
    const gop = (bs().locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse return;
    const inf = gop.mode.info;
    var shifts: [3]u5 = .{ 16, 8, 0 };
    switch (inf.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => {},
        .red_green_blue_reserved_8_bit_per_color => shifts = .{ 0, 8, 16 },
        else => return,
    }
    gfx.init(.{
        .base = @ptrFromInt(@as(usize, @intCast(gop.mode.frame_buffer_base))),
        .width = inf.horizontal_resolution,
        .height = inf.vertical_resolution,
        .stride = inf.pixels_per_scan_line * 4,
        .red_shift = shifts[0],
        .green_shift = shifts[1],
        .blue_shift = shifts[2],
    });
    use_gfx = true;
    sio = bs().locateProtocol(uefi.protocol.SerialIo, null) catch null;
    serialWrite("\x1b[2J\x1b[H");
    apply();
}

fn out() ?*uefi.protocol.SimpleTextOutput {
    return uefi.system_table.con_out;
}

fn bs() *uefi.tables.BootServices {
    return uefi.system_table.boot_services.?;
}

// -- output ------------------------------------------------------------------

/// Print a UTF-8 string. Characters outside the BMP are shown as '?'.
pub fn print(s: []const u8) void {
    if (use_gfx) {
        // The serial terminal gets the UTF-8 itself, with CR before LF.
        var start: usize = 0;
        for (s, 0..) |c, i| {
            if (c == '\n') {
                serialWrite(s[start..i]);
                serialWrite("\r\n");
                start = i + 1;
            }
        }
        serialWrite(s[start..]);
        const view = std.unicode.Utf8View.init(s) catch {
            for (s) |c| gfx.putc(c);
            return;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| gfx.putc(cp);
        return;
    }
    const con = out() orelse return;
    var buf: [256:0]u16 = undefined;
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(s) catch {
        // Not valid UTF-8: send the bytes as they are.
        for (s) |c| {
            if (n + 2 >= buf.len) flush(con, &buf, &n);
            if (c == '\n') {
                buf[n] = '\r';
                n += 1;
            }
            buf[n] = c;
            n += 1;
        }
        flush(con, &buf, &n);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (n + 2 >= buf.len) flush(con, &buf, &n);
        if (cp == '\n') {
            buf[n] = '\r';
            n += 1;
        }
        buf[n] = if (cp > 0xffff) '?' else @intCast(cp);
        n += 1;
    }
    flush(con, &buf, &n);
}

fn flush(con: *uefi.protocol.SimpleTextOutput, buf: *[256:0]u16, n: *usize) void {
    if (n.* == 0) return;
    buf[n.*] = 0;
    _ = con.outputString(buf) catch {};
    n.* = 0;
}

/// Print `v` in decimal.
pub fn printDec(v: u64) void {
    var b: [24]u8 = undefined;
    print(std.fmt.bufPrint(&b, "{d}", .{v}) catch return);
}

/// Print `v` in hexadecimal with a 0x prefix, without leading zeros.
pub fn printHex(v: u64) void {
    var b: [24]u8 = undefined;
    print(std.fmt.bufPrint(&b, "0x{x}", .{v}) catch return);
}

/// Formatted print, for the few places that need it.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    print(std.fmt.bufPrint(&b, fmt, args) catch return);
}

/// Clear the screen and home the cursor.
pub fn clear() void {
    if (use_gfx) {
        gfx.clear();
        serialWrite("\x1b[2J\x1b[H");
        return;
    }
    const con = out() orelse return;
    _ = con.clearScreen() catch {};
}

/// Move the cursor to column `x`, row `y` (both from 1, as in FreeBSD's
/// screen.lua).
pub fn gotoxy(x: usize, y: usize) void {
    if (use_gfx) {
        gfx.gotoxy(x -| 1, y -| 1);
        var b: [24]u8 = undefined;
        serialWrite(std.fmt.bufPrint(&b, "\x1b[{d};{d}H", .{ @max(y, 1), @max(x, 1) }) catch return);
        return;
    }
    const con = out() orelse return;
    _ = con.setCursorPosition(x -| 1, y -| 1) catch {};
}

/// Show or hide the cursor.
pub fn cursor(visible: bool) void {
    if (use_gfx) {
        gfx.showCursor(visible);
        serialWrite(if (visible) "\x1b[?25h" else "\x1b[?25l");
        return;
    }
    const con = out() orelse return;
    _ = con.enableCursor(visible) catch {};
}

/// The VGA palette the BSD consoles use, normal then bright.
const palette: [2][8]u32 = .{
    .{ 0x000000, 0xaa0000, 0x00aa00, 0xaa5500, 0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa },
    .{ 0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff },
};

fn apply() void {
    if (use_gfx) {
        gfx.setColor(palette[@intFromBool(bright)][@backingInt(fg)]);
        var b: [16]u8 = undefined;
        serialWrite(std.fmt.bufPrint(&b, "\x1b[{d};3{d}m", .{ @intFromBool(bright), @backingInt(fg) }) catch return);
        return;
    }
    const con = out() orelse return;
    const f: Attr.ForegroundColor = switch (fg) {
        .black => if (bright) .darkgray else .black,
        .red => if (bright) .lightred else .red,
        .green => if (bright) .lightgreen else .green,
        .yellow => if (bright) .yellow else .brown,
        .blue => if (bright) .lightblue else .blue,
        .magenta => if (bright) .lightmagenta else .magenta,
        .cyan => if (bright) .lightcyan else .cyan,
        .white => if (bright) .white else .lightgray,
    };
    _ = con.setAttribute(.{ .foreground = f, .background = .black }) catch {};
}

/// Select the text colour; `hi` picks the bright variant (FreeBSD's
/// color.highlight()).
pub fn setColor(c: Color, hi: bool) void {
    fg = c;
    bright = hi;
    apply();
}

/// Back to the default colour (light grey).
pub fn resetColor() void {
    setColor(.white, false);
}

/// The text screen size in cells.
pub fn size() struct { cols: usize, rows: usize } {
    if (use_gfx) return .{ .cols = gfx.cols(), .rows = gfx.rows() };
    const con = out() orelse return .{ .cols = 80, .rows = 25 };
    const g = con.queryMode(con.mode.mode) catch return .{ .cols = 80, .rows = 25 };
    return .{ .cols = g.columns, .rows = g.rows };
}

// -- input -------------------------------------------------------------------

/// The next key press, or null when none is waiting.
pub fn getKey() ?Key {
    const in = uefi.system_table.con_in orelse return null;
    const k = in.readKeyStroke() catch return null;
    return switch (k.scan_code) {
        0 => switch (k.unicode_char) {
            '\r', '\n' => .enter,
            0x08, 0x7f => .backspace,
            0x1b => .escape,
            0x20...0x7e => .{ .char = @intCast(k.unicode_char) },
            else => .other,
        },
        0x01 => .up,
        0x02 => .down,
        // Serial terminals send DEL (0x7f) for Backspace, which the firmware
        // reports as the Delete key.
        0x08 => .backspace,
        0x17 => .escape,
        else => .other,
    };
}

/// Wait for a key press.
pub fn waitKey() Key {
    while (true) {
        if (getKey()) |k| return k;
        delay(10_000);
    }
}

/// Busy-wait `us` microseconds.
pub fn delay(us: usize) void {
    _ = bs().stall(us) catch {};
}

/// Reset the machine.
pub fn reboot() noreturn {
    uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
}

// -- firmware identity ---------------------------------------------------------

/// Print the firmware's UEFI version, e.g. "2.70".
pub fn printEfiVersion() void {
    const r: u32 = uefi.system_table.hdr.revision;
    const major: u32 = r >> 16;
    const minor: u32 = r & 0xffff;
    // UEFI encodes 2.7 as minor 70.
    printf("{d}.{d:0>2}", .{ major, if (minor < 10) minor * 10 else minor });
}

/// Print the firmware vendor and revision, e.g. "EDK II (rev 1.00)".
pub fn printFirmware() void {
    const v: [*:0]const u16 = uefi.system_table.firmware_vendor;
    var b: [64]u8 = undefined;
    var i: usize = 0;
    while (v[i] != 0 and i < b.len) : (i += 1) b[i] = if (v[i] < 0x80) @intCast(v[i]) else '?';
    print(b[0..i]);
    const fr: u32 = uefi.system_table.firmware_revision;
    printf(" (rev {d}.{d:0>2})", .{ fr >> 16, fr & 0xffff });
}

// -- files -------------------------------------------------------------------

/// Open the volume the loader was started from; all paths are relative to it.
pub fn openBootVolume() bool {
    const li = bs().handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return false;
    const image = li orelse return false;
    const device = image.device_handle orelse return false;
    const fsp = bs().handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return false;
    const fs = fsp orelse return false;
    root_dir = fs.openVolume() catch return false;
    return true;
}

/// Convert a loader path ("/boot/kernel/kernel") to a UEFI path.
fn toUefiPath(path: []const u8, buf: *[256:0]u16) ?[*:0]const u16 {
    if (path.len >= buf.len) return null;
    for (path, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    buf[path.len] = 0;
    return buf;
}

fn open(path: []const u8) ?*uefi.protocol.File {
    const r = root_dir orelse return null;
    var pbuf: [256:0]u16 = undefined;
    const p = toUefiPath(path, &pbuf) orelse return null;
    return r.open(p, .read, .{}) catch null;
}

/// Size of the file at `path`, or null when it does not exist.
pub fn fileSize(path: []const u8) ?u64 {
    const f = open(path) orelse return null;
    defer f.close() catch {};
    var info_buf: [512]u8 align(8) = undefined;
    const isz = f.getInfoSize(.file) catch return null;
    if (isz > info_buf.len) return null;
    const inf = f.getInfo(.file, info_buf[0..isz]) catch return null;
    if (inf.attribute.directory) return null;
    return inf.file_size;
}

/// Read the whole file at `path` into fresh pages. Returns null when it does
/// not exist or cannot be read.
pub fn readFile(path: []const u8) ?[]u8 {
    const sz: u64 = fileSize(path) orelse return null;
    const f = open(path) orelse return null;
    defer f.close() catch {};
    const pages: usize = @intCast((sz + 4095) / 4096 + 1);
    const mem = bs().allocatePages(.any, .loader_data, pages) catch return null;
    const data: []u8 = @as([*]u8, @ptrCast(mem.ptr))[0..@intCast(sz)];
    var got: usize = 0;
    while (got < data.len) {
        const want: usize = @min(data.len - got, 1 << 20);
        const n = f.read(data[got .. got + want]) catch return null;
        if (n == 0) break;
        got += n;
    }
    if (got != data.len) return null;
    return data;
}

/// Print the entries of directory `path`, FreeBSD ls style ("d name" for
/// directories, " size name" for files). Returns false when it cannot be read.
pub fn listDir(path: []const u8) bool {
    const dir = open(path) orelse return false;
    defer dir.close() catch {};
    var buf: [1024]u8 align(8) = undefined;
    while (true) {
        const n = dir.read(&buf) catch return false;
        if (n == 0) break;
        const inf: *const uefi.protocol.File.Info.File = @ptrCast(&buf);
        const name = inf.getFileName();
        var nb: [128]u8 = undefined;
        var i: usize = 0;
        while (name[i] != 0 and i < nb.len) : (i += 1) nb[i] = if (name[i] < 0x80) @intCast(name[i]) else '?';
        if (inf.attribute.directory) {
            printf(" d  {s}\n", .{nb[0..i]});
        } else {
            printf("    {s}\t{d}\n", .{ nb[0..i], inf.file_size });
        }
    }
    return true;
}
