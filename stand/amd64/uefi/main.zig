// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Renux UEFI boot loader.
//
// The third stage of the Renux boot (FreeBSD's stand/efi/loader, written in
// Zig instead of C). The firmware loads this PE image as \EFI\BOOT\BOOTX64.EFI;
// it locates the volume it came from, reads the kernel, and will hand control
// to it. The low-level entry comes from Zig's std.start (EfiMain) and the
// hand-off follows the same boot protocol the kernel already speaks.

const std: type = @import("std");
const uefi: type = std.os.uefi;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

/// Bring up COM1 at 115200 8N1, so the loader can report progress on a serial
/// line (the firmware console only reaches the display).
fn serialInit() void {
    outb(0x3f8 + 1, 0x00);
    outb(0x3f8 + 3, 0x80);
    outb(0x3f8 + 0, 0x01);
    outb(0x3f8 + 1, 0x00);
    outb(0x3f8 + 3, 0x03);
    outb(0x3f8 + 2, 0xc7);
}

fn serialPut(c: u8) void {
    while ((inb(0x3f8 + 5) & 0x20) == 0) {}
    outb(0x3f8, c);
}

/// Path of the kernel on the ESP/ISO, in UEFI (UTF-16) form.
const kernel_path: [*:0]const u16 =
    std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\renux\\kernel");

/// Write `s` to the firmware console, ignoring errors (early boot has nowhere
/// to report them).
fn say(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            serialPut('\r');
        }
        serialPut(c);
    }
    const con = uefi.system_table.con_out orelse return;
    // The console wants UTF-16; convert on the fly, one code unit per byte
    // (the loader only prints ASCII).
    var buf: [128:0]u16 = undefined;
    if (s.len >= buf.len) {
        return;
    }
    for (s, 0..) |c, i| {
        buf[i] = c;
    }
    buf[s.len] = 0;
    _ = con.outputString(&buf) catch {};
}

pub fn main() uefi.Error!void {
    serialInit();
    const bs = uefi.system_table.boot_services orelse return error.Unexpected;

    say("Renux loader\n");

    // The device this loader was loaded from.
    const li = try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) orelse
        return error.Unexpected;
    const device = li.device_handle orelse return error.Unexpected;

    // Its simple file system, and the root directory.
    const fs = try bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) orelse
        return error.Unexpected;
    const root = try fs.openVolume();

    const file = root.open(kernel_path, .read, .{}) catch {
        say("loader: kernel not found\n");
        return error.NotFound;
    };
    defer file.close() catch {};

    const size = file.readSize() catch 0;
    say("loader: found kernel\n");
    var digits: [24]u8 = undefined;
    say(dec(&digits, size));
    say(" bytes\n");
}

/// Format `v` as decimal into `buf`, returning the slice used.
fn dec(buf: []u8, v: u64) []const u8 {
    var i: usize = buf.len;
    var n: u64 = v;
    if (n == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (n != 0 and i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    return buf[i..];
}
