// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The loader's platform services on UEFI: console, keyboard, files, time.
//
// The counterpart of FreeBSD's stand/efi/libefi (efi_console.c, efipart.c,
// framebuffer.c). The firmware-independent loader (bootloader/common) imports
// this file as the "platform" module and reaches the firmware only through
// the functions below, so a loader for other firmware provides a module with
// the same declarations:
//
//   output   print, printf, clear, gotoxy, cursor, setColor, resetColor
//   input    Key, getKey, waitKey
//   files    openBootVolume, fileSize, readFile, freeFile, listDir
//   machine  delay, reboot, printEfiVersion, printFirmware
//
// Output goes one of two ways, chosen once by `consInit`:
//
//   graphics  on a linear 32-bit GOP framebuffer the loader draws its own
//             text over the whole screen (bootloader/common/gfx_fb.zig), and
//             mirrors it to the serial console with ANSI escape sequences, as
//             FreeBSD's loader does;
//   text      otherwise, the firmware's SimpleTextOutput console.
//
// Input always comes from the firmware's SimpleTextInput, which merges the
// keyboard and the serial console.

const std: type = @import("std");
const uefi: type = std.os.uefi;
const SimpleTextOutput: type = uefi.protocol.SimpleTextOutput;
const libefi: type = @import("libefi");
const gfx: type = @import("gfx_fb");

/// The 8 text colours the loader menu uses (FreeBSD's color.lua), in ANSI
/// order, so a colour's value is its ANSI number.
pub const Color: type = enum(u3) { black, red, green, yellow, blue, magenta, cyan, white };

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

/// The root directory of the boot volume, set by `openBootVolume`.
var root_dir: ?*uefi.protocol.File = null;
/// The current text colour.
var foreground: Color = .white;
var bright: bool = false;
/// True when the loader draws on the framebuffer itself (graphics output),
/// false when it uses the firmware's text console.
var use_gfx: bool = false;

// -- serial mirror (graphics output only) ------------------------------------
//
// The serial port is reached through the firmware's Serial I/O protocol, as
// FreeBSD's stand/efi/libefi/eficom.c does, not by programming a UART: the
// firmware knows where the console port is on every architecture.

var serial: ?*uefi.protocol.SerialIo = null;

/// ANSI sequences sent to the serial console.
const ANSI_CLEAR_AND_HOME: []const u8 = "\x1b[2J\x1b[H";
const ANSI_SHOW_CURSOR: []const u8 = "\x1b[?25h";
const ANSI_HIDE_CURSOR: []const u8 = "\x1b[?25l";

/// Write bytes to the serial console, when the firmware has one.
fn serialWrite(bytes: []const u8) void {
    const port: *uefi.protocol.SerialIo = serial orelse return;
    var written: usize = 0;
    while (written < bytes.len) {
        const n: usize = port.write(bytes[written..]) catch return;
        if (n == 0) return;
        written += n;
    }
}

/// Choose the console: draw on the GOP framebuffer when it is a linear
/// 32-bit one, otherwise keep the firmware's text console.
pub fn consInit() void {
    const gop: *uefi.protocol.GraphicsOutput = (libefi.bootServices().locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse return;
    const mode: *const uefi.protocol.GraphicsOutput.Mode.Info = gop.mode.info;
    // Bit position of the red, green and blue bytes in a 32-bit pixel.
    const shifts: [3]u5 = switch (mode.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => .{ 16, 8, 0 },
        .red_green_blue_reserved_8_bit_per_color => .{ 0, 8, 16 },
        .bit_mask, .blt_only => return,
    };
    gfx.init(.{
        .base = @ptrFromInt(@as(usize, @intCast(gop.mode.frame_buffer_base))),
        .width = mode.horizontal_resolution,
        .height = mode.vertical_resolution,
        .stride = mode.pixels_per_scan_line * @sizeOf(u32),
        .red_shift = shifts[0],
        .green_shift = shifts[1],
        .blue_shift = shifts[2],
    });
    use_gfx = true;
    serial = libefi.bootServices().locateProtocol(uefi.protocol.SerialIo, null) catch null;
    serialWrite(ANSI_CLEAR_AND_HOME);
    applyColor();
}

/// The firmware's text console.
fn textConsole() ?*SimpleTextOutput {
    return uefi.system_table.con_out;
}

// -- output ------------------------------------------------------------------

/// Print a UTF-8 string. On the firmware console, characters outside the
/// Basic Multilingual Plane are shown as '?'.
pub fn print(text: []const u8) void {
    if (use_gfx) {
        printGraphics(text);
    } else {
        printText(text);
    }
}

/// Graphics output: the serial terminal gets the UTF-8 itself (with CR
/// before LF), the framebuffer the decoded code points.
fn printGraphics(text: []const u8) void {
    var line_start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            serialWrite(text[line_start..i]);
            serialWrite("\r\n");
            line_start = i + 1;
        }
    }
    serialWrite(text[line_start..]);

    const utf8: std.unicode.Utf8View = std.unicode.Utf8View.init(text) catch {
        // Not valid UTF-8: draw the bytes as Latin-1.
        for (text) |c| gfx.putc(c);
        return;
    };
    var it: std.unicode.Utf8Iterator = utf8.iterator();
    while (it.nextCodepoint()) |cp| gfx.putc(cp);
}

/// UCS-2 characters gathered before each call to the firmware.
const TEXT_CHUNK: usize = 256;

/// Text output: convert to UCS-2 in chunks, with CR before LF.
fn printText(text: []const u8) void {
    const con: *SimpleTextOutput = textConsole() orelse return;
    var chunk: Ucs2Chunk = .{ .con = con };
    if (std.unicode.Utf8View.init(text)) |utf8| {
        var it: std.unicode.Utf8Iterator = utf8.iterator();
        while (it.nextCodepoint()) |cp| chunk.put(if (cp > 0xffff) '?' else @intCast(cp));
    } else |_| {
        // Not valid UTF-8: send the bytes as they are.
        for (text) |c| chunk.put(c);
    }
    chunk.flush();
}

/// A buffer of UCS-2 characters on their way to the firmware console.
const Ucs2Chunk: type = struct {
    con: *SimpleTextOutput,
    buf: [TEXT_CHUNK:0]u16 = undefined,
    len: usize = 0,

    /// Add one character, expanding LF to CR LF.
    fn put(chunk: *Ucs2Chunk, c: u16) void {
        // Room for a CR, the character and the terminating NUL.
        if (chunk.len + 2 >= chunk.buf.len) chunk.flush();
        if (c == '\n') {
            chunk.buf[chunk.len] = '\r';
            chunk.len += 1;
        }
        chunk.buf[chunk.len] = c;
        chunk.len += 1;
    }

    /// Hand the gathered characters to the firmware.
    fn flush(chunk: *Ucs2Chunk) void {
        if (chunk.len == 0) return;
        chunk.buf[chunk.len] = 0;
        _ = chunk.con.outputString(&chunk.buf) catch {};
        chunk.len = 0;
    }
};

/// Formatted print (std.fmt syntax). Output longer than 256 bytes is dropped.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

/// Clear the screen and home the cursor.
pub fn clear() void {
    if (use_gfx) {
        gfx.clear();
        serialWrite(ANSI_CLEAR_AND_HOME);
        return;
    }
    const con: *SimpleTextOutput = textConsole() orelse return;
    con.clearScreen() catch {};
}

/// Move the cursor to column `x`, row `y`, both counted from 1 (as in
/// FreeBSD's screen.lua).
pub fn gotoxy(x: usize, y: usize) void {
    if (use_gfx) {
        gfx.gotoxy(x -| 1, y -| 1);
        var buf: [24]u8 = undefined;
        serialWrite(std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ @max(y, 1), @max(x, 1) }) catch return);
        return;
    }
    const con: *SimpleTextOutput = textConsole() orelse return;
    con.setCursorPosition(x -| 1, y -| 1) catch {};
}

/// Show or hide the cursor.
pub fn cursor(visible: bool) void {
    if (use_gfx) {
        gfx.showCursor(visible);
        serialWrite(if (visible) ANSI_SHOW_CURSOR else ANSI_HIDE_CURSOR);
        return;
    }
    const con: *SimpleTextOutput = textConsole() orelse return;
    _ = con.enableCursor(visible) catch {};
}

/// The VGA palette the BSD consoles use (0xRRGGBB), normal then bright.
const palette: [2][8]u32 = .{
    .{ 0x000000, 0xaa0000, 0x00aa00, 0xaa5500, 0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa },
    .{ 0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff },
};

/// Make the current colour take effect on the active console.
fn applyColor() void {
    if (use_gfx) {
        gfx.setColor(palette[@intFromBool(bright)][@backingInt(foreground)]);
        // SGR: 0 or 1 (bright), then 30 + colour.
        var buf: [16]u8 = undefined;
        serialWrite(std.fmt.bufPrint(&buf, "\x1b[{d};3{d}m", .{ @intFromBool(bright), @backingInt(foreground) }) catch return);
        return;
    }
    const con: *SimpleTextOutput = textConsole() orelse return;
    const fg: SimpleTextOutput.Attribute.ForegroundColor = switch (foreground) {
        .black => if (bright) .darkgray else .black,
        .red => if (bright) .lightred else .red,
        .green => if (bright) .lightgreen else .green,
        .yellow => if (bright) .yellow else .brown,
        .blue => if (bright) .lightblue else .blue,
        .magenta => if (bright) .lightmagenta else .magenta,
        .cyan => if (bright) .lightcyan else .cyan,
        .white => if (bright) .white else .lightgray,
    };
    con.setAttribute(.{ .foreground = fg, .background = .black }) catch {};
}

/// Select the text colour; `highlight` picks the bright variant (FreeBSD's
/// color.highlight()).
pub fn setColor(color: Color, highlight: bool) void {
    foreground = color;
    bright = highlight;
    applyColor();
}

/// Back to the default colour (light grey).
pub fn resetColor() void {
    setColor(.white, false);
}

// -- input -------------------------------------------------------------------

/// UEFI scan codes the loader understands (UEFI spec, "EFI Scan Codes for
/// EFI_SIMPLE_TEXT_INPUT_PROTOCOL"). Scan code 0 means "a printable key: see
/// the Unicode character".
const SCAN_NULL: u16 = 0x00;
const SCAN_UP: u16 = 0x01;
const SCAN_DOWN: u16 = 0x02;
const SCAN_DELETE: u16 = 0x08;
const SCAN_ESC: u16 = 0x17;

/// The next key press, or null when none is waiting.
pub fn getKey() ?Key {
    const in: *uefi.protocol.SimpleTextInput = uefi.system_table.con_in orelse return null;
    const key: uefi.protocol.SimpleTextInput.Key.Input = in.readKeyStroke() catch return null;
    return switch (key.scan_code) {
        SCAN_NULL => switch (key.unicode_char) {
            '\r', '\n' => .enter,
            std.ascii.control_code.bs, std.ascii.control_code.del => .backspace,
            std.ascii.control_code.esc => .escape,
            ' '...'~' => .{ .char = @intCast(key.unicode_char) },
            else => .other,
        },
        SCAN_UP => .up,
        SCAN_DOWN => .down,
        // Serial terminals send DEL (0x7f) for Backspace, which the firmware
        // reports as the Delete key.
        SCAN_DELETE => .backspace,
        SCAN_ESC => .escape,
        else => .other,
    };
}

/// How often `waitKey` polls the keyboard.
const KEY_POLL_INTERVAL_US: usize = 10_000;

/// Wait for a key press.
pub fn waitKey() Key {
    while (true) {
        if (getKey()) |key| return key;
        delay(KEY_POLL_INTERVAL_US);
    }
}

/// Busy-wait `microseconds`.
pub fn delay(microseconds: usize) void {
    libefi.bootServices().stall(microseconds) catch {};
}

/// Reset the machine.
pub fn reboot() noreturn {
    uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
}

// -- firmware identity -------------------------------------------------------

/// Print the firmware's UEFI version, e.g. "2.70".
pub fn printEfiVersion() void {
    const revision: u32 = uefi.system_table.hdr.revision;
    const major: u32 = revision >> 16;
    const minor: u32 = revision & 0xffff;
    // UEFI encodes 2.7 as minor 70 and 2.10 as minor 100; a one-digit minor
    // is in tenths.
    printf("{d}.{d:0>2}", .{ major, if (minor < 10) minor * 10 else minor });
}

/// Print the firmware vendor and revision, e.g. "EDK II (rev 1.00)".
pub fn printFirmware() void {
    const vendor: [*:0]const u16 = uefi.system_table.firmware_vendor;
    var buf: [64]u8 = undefined;
    print(libefi.ucs2ToAscii(std.mem.span(vendor), &buf));
    const revision: u32 = uefi.system_table.firmware_revision;
    printf(" (rev {d}.{d:0>2})", .{ revision >> 16, revision & 0xffff });
}

// -- files -------------------------------------------------------------------

/// Longest path the loader opens, in characters.
const PATH_MAX: usize = 255;

/// Open the volume the loader was started from; all paths are relative to
/// it. Returns false when the firmware cannot give it.
pub fn openBootVolume() bool {
    const bs: *uefi.tables.BootServices = libefi.bootServices();
    const image: *uefi.protocol.LoadedImage = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return false) orelse return false;
    const device: uefi.Handle = image.device_handle orelse return false;
    const fs: *uefi.protocol.SimpleFileSystem = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return false) orelse return false;
    root_dir = fs.openVolume() catch return false;
    return true;
}

/// Convert a loader path ("/boot/kernel/kernel") to a UEFI one
/// ("\boot\kernel\kernel").
fn toUefiPath(path: []const u8, buf: *[PATH_MAX:0]u16) ?[*:0]const u16 {
    if (path.len > PATH_MAX) return null;
    for (path, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    buf[path.len] = 0;
    return buf;
}

/// Open the file or directory at `path` for reading.
fn open(path: []const u8) ?*uefi.protocol.File {
    const root: *uefi.protocol.File = root_dir orelse return null;
    var buf: [PATH_MAX:0]u16 = undefined;
    const uefi_path: [*:0]const u16 = toUefiPath(path, &buf) orelse return null;
    return root.open(uefi_path, .read, .{}) catch null;
}

/// Size of the file at `path`, or null when there is no such file (a
/// directory does not count).
pub fn fileSize(path: []const u8) ?u64 {
    const file: *uefi.protocol.File = open(path) orelse return null;
    defer file.close() catch {};
    var info_buf: [512]u8 align(8) = undefined;
    const info_size: usize = file.getInfoSize(.file) catch return null;
    if (info_size > info_buf.len) return null;
    const info: *const uefi.protocol.File.Info.File = file.getInfo(.file, info_buf[0..info_size]) catch return null;
    if (info.attribute.directory) return null;
    return info.file_size;
}

/// Bytes read per call to the firmware.
const READ_CHUNK: usize = 1 << 20;

/// Read the whole file at `path` into fresh, page-aligned loader memory.
/// Returns null when it does not exist or cannot be read. Give the memory
/// back with `freeFile`.
pub fn readFile(path: []const u8) ?[]u8 {
    const size: u64 = fileSize(path) orelse return null;
    const file: *uefi.protocol.File = open(path) orelse return null;
    defer file.close() catch {};
    const pages: libefi.Pages = libefi.allocatePages(filePages(size)) orelse return null;
    const data: []u8 = @as([*]u8, @ptrCast(pages.ptr))[0..@intCast(size)];
    var got: usize = 0;
    while (got < data.len) {
        const want: usize = @min(data.len - got, READ_CHUNK);
        const n: usize = file.read(data[got..][0..want]) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got != data.len) {
        libefi.freePages(pages);
        return null;
    }
    return data;
}

/// Give back the memory of a file returned by `readFile`.
pub fn freeFile(data: []u8) void {
    const pages: [*]align(libefi.PAGE_SIZE) uefi.Page = @ptrCast(@alignCast(data.ptr));
    libefi.freePages(pages[0..filePages(data.len)]);
}

/// Pages `readFile` allocates for a file of `size` bytes (one spare page, so
/// an empty file still gets memory).
fn filePages(size: u64) usize {
    return libefi.pagesFor(size) + 1;
}

/// Print the entries of the directory at `path`: " d  name" for
/// directories, "    name<TAB>size" for files. Returns false when it cannot
/// be read.
pub fn listDir(path: []const u8) bool {
    const dir: *uefi.protocol.File = open(path) orelse return false;
    defer dir.close() catch {};
    var buf: [1024]u8 align(8) = undefined;
    while (true) {
        // Each read of a directory returns one entry; 0 bytes means the end.
        const n: usize = dir.read(&buf) catch return false;
        if (n == 0) break;
        const entry: *const uefi.protocol.File.Info.File = @ptrCast(&buf);
        var name_buf: [128]u8 = undefined;
        const name: []const u8 = libefi.ucs2ToAscii(std.mem.span(entry.getFileName()), &name_buf);
        if (entry.attribute.directory) {
            printf(" d  {s}\n", .{name});
        } else {
            printf("    {s}\t{d}\n", .{ name, entry.file_size });
        }
    }
    return true;
}
