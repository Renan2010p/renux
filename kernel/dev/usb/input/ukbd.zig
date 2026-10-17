// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// USB keyboard.
//
// The Zig counterpart of FreeBSD's sys/dev/usb/input/ukbd.c, reduced to the
// HID boot protocol every USB keyboard speaks: an 8-byte report of modifier
// bits and up to six pressed keys, read from the keyboard's interrupt IN
// endpoint. Keys are found pressed by comparing each report with the one
// before, translated from HID usages to PC set 1 scan codes (as ukbd's
// ukbd_trtab does) and fed through the same MF-II keymap and escape
// sequences as the PS/2 keyboard. USB keyboards do not repeat keys
// themselves, so the driver does, from the clock tick (FreeBSD's defaults:
// 500 ms delay, about 30 characters a second). Caps Lock and Num Lock
// toggle the keyboard's LEDs with a SET_REPORT request.

const arch: type = @import("../../../arch/arch.zig");
const prf: type = @import("../../../core/subr_prf.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");
const cons: type = @import("../../cons.zig");
const keymap: type = @import("../../pckbport/wskbdmap_mfii.zig");
const wskbdutil: type = @import("../../wscons/wskbdutil.zig");
const xhci: type = @import("../controller/xhci.zig");
const usb: type = @import("../usb.zig");
const usb_device: type = @import("../usb_device.zig");

const MAXUNITS: usize = 4;

/// Modifier byte of the boot report.
const MOD_LCTRL: u8 = 0x01;
const MOD_LSHIFT: u8 = 0x02;
const MOD_LALT: u8 = 0x04;
const MOD_RCTRL: u8 = 0x10;
const MOD_RSHIFT: u8 = 0x20;
const MOD_RALT: u8 = 0x40;
const MOD_CTRL: u8 = MOD_LCTRL | MOD_RCTRL;
const MOD_SHIFT: u8 = MOD_LSHIFT | MOD_RSHIFT;
const MOD_ALT: u8 = MOD_LALT | MOD_RALT;

/// LED bits of the output report.
const LED_NUM: u8 = 0x01;
const LED_CAPS: u8 = 0x02;

/// HID keyboard usages handled outside the keymap.
const KEY_ERROR_ROLLOVER: u8 = 0x01;
const KEY_CAPSLOCK: u8 = 0x39;
const KEY_F1: u8 = 0x3a;
const KEY_F12: u8 = 0x45;
const KEY_INSERT: u8 = 0x49;
const KEY_UP: u8 = 0x52;
const KEY_NUMLOCK: u8 = 0x53;
const KEY_KP_SLASH: u8 = 0x54;
const KEY_KP_ENTER: u8 = 0x58;
const KEY_KP_1: u8 = 0x59;
const KEY_KP_DOT: u8 = 0x63;
const KEY_NONUS_BACKSLASH: u8 = 0x64; // the extra key left of Z (ABNT2: \ |)
const KEY_INTL1: u8 = 0x87; // ABNT2: / ?

/// Typematic repeat, in clock ticks.
const REPEAT_DELAY: u64 = arch.clock.HZ / 2;
const REPEAT_RATE: u64 = 3;

/// HID usage → PC set 1 make code, for the keys the MF-II map translates
/// (letters, digits, punctuation, the keypad). Zero: handled by usage.
const trtab: [0x64]u8 = .{
    0x00, 0x00, 0x00, 0x00, 0x1e, 0x30, 0x2e, 0x20, // 00-07: a b c d
    0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, // 08-0f: e .. l
    0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, // 10-17: m .. t
    0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c, 0x02, 0x03, // 18-1f: u .. z 1 2
    0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, // 20-27: 3 .. 0
    0x1c, 0x01, 0x0e, 0x0f, 0x39, 0x0c, 0x0d, 0x1a, // 28-2f: Enter Esc BS Tab Space - = [
    0x1b, 0x2b, 0x2b, 0x27, 0x28, 0x29, 0x33, 0x34, // 30-37: ] \ #  ; ' ` , .
    0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 38-3f: / CapsLock F1-F6
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 40-47: F7-F12 PrtSc ScrLk
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 48-4f: Pause, editing, Right
    0x00, 0x00, 0x00, 0x00, 0x00, 0x37, 0x4a, 0x4e, // 50-57: Left Down Up NumLk KP/ KP* KP- KP+
    0x00, 0x4f, 0x50, 0x51, 0x4b, 0x4c, 0x4d, 0x47, // 58-5f: KPEnter KP1 .. KP7
    0x48, 0x49, 0x52, 0x53, // 60-63: KP8 KP9 KP0 KP.
};

/// The editing and cursor keys (usages 0x49-0x52), as extended set 1 codes:
/// Insert Home PgUp Delete End PgDn Right Left Down Up.
const navtab: [10]u8 = .{ 0x52, 0x47, 0x49, 0x53, 0x4f, 0x51, 0x4d, 0x4b, 0x50, 0x48 };

const Softc: type = struct {
    used: bool = false,
    unit: u32 = 0,
    dev: *xhci.Device = undefined,
    iface: u8 = 0,
    /// The previous report.
    prev: [8]u8 = @splat(0),
    capslock: bool = false,
    numlock: bool = true,
    /// LED state wanted, and last sent to the keyboard.
    leds: u8 = 0,
    leds_sent: u8 = 0xff,
    repeat_key: u8 = 0,
    repeat_at: u64 = 0,
};

var softc: [MAXUNITS]Softc = @splat(.{});

/// A boot-protocol keyboard interface.
pub fn probe(id: *const usb.InterfaceDescriptor) bool {
    return id.bInterfaceClass == usb.UICLASS_HID and id.bInterfaceSubClass == usb.UISUBCLASS_BOOT and
        id.bInterfaceProtocol == usb.UIPROTO_BOOT_KEYBOARD;
}

fn classRequest(sc: *Softc, request: u8, value: u16, data: []u8) ?usize {
    return xhci.control(sc.dev, .{
        .bmRequestType = usb.UT_WRITE_CLASS_INTERFACE,
        .bRequest = request,
        .wValue = value,
        .wIndex = sc.iface,
        .wLength = @intCast(data.len),
    }, data);
}

fn ledRequest(sc: *const Softc) usb.DeviceRequest {
    return .{
        .bmRequestType = usb.UT_WRITE_CLASS_INTERFACE,
        .bRequest = usb.UR_SET_REPORT,
        .wValue = usb.UHID_OUTPUT_REPORT << 8,
        .wIndex = sc.iface,
        .wLength = 1,
    };
}

fn ledState(sc: *const Softc) u8 {
    return (if (sc.numlock) LED_NUM else 0) | (if (sc.capslock) LED_CAPS else 0);
}

pub fn attach(dev: *xhci.Device, info: *const usb_device.Info, id: *const usb.InterfaceDescriptor, ep: *const usb.EndpointDescriptor) bool {
    // The lowest free unit, as FreeBSD numbers a re-plugged keyboard.
    const unit: usize = for (&softc, 0..) |*s, i| {
        if (!s.used) break i;
    } else return false;
    const sc: *Softc = &softc[unit];
    sc.* = .{ .used = true, .unit = @intCast(unit), .dev = dev, .iface = id.bInterfaceNumber };

    // Boot protocol, and reports only when something changes. Both are
    // optional for a boot keyboard; a stall is not fatal.
    var none: [0]u8 = .{};
    _ = classRequest(sc, usb.UR_SET_PROTOCOL, 0, none[0..]);
    _ = classRequest(sc, usb.UR_SET_IDLE, 0, none[0..]);
    sc.leds = ledState(sc);
    var led: [1]u8 = .{sc.leds};
    if (xhci.control(dev, ledRequest(sc), led[0..]) != null) sc.leds_sent = sc.leds;

    if (!xhci.openInterruptIn(dev, ep, input, sc)) {
        sc.used = false;
        return false;
    }
    dev.driver_ctx = sc;
    dev.driver_detach = detach;

    // FreeBSD's line, the device's description inside the brackets.
    const d: *const usb.DeviceDescriptor = &info.desc;
    prf.printf("ukbd%u: <%s, class %u/%u, rev %u.%u%u/%u.%u%u, addr %u> on %s\n", .{
        sc.unit,                  info.nameSlice(),
        d.bDeviceClass,           d.bDeviceSubClass,
        d.bcdUSB >> 8,            (d.bcdUSB >> 4) & 0xf,
        d.bcdUSB & 0xf,           d.bcdDevice >> 8,
        (d.bcdDevice >> 4) & 0xf, d.bcdDevice & 0xf,
        dev.address(),            dev.busName(),
    });
    return true;
}

fn detach(ctx: ?*anyopaque) void {
    const sc: *Softc = @ptrCast(@alignCast(ctx.?));
    sc.used = false;
    prf.printf("ukbd%u: at %s, port %u (disconnected)\n", .{ sc.unit, sc.dev.busName(), sc.dev.port });
}

/// Send what one key produces to the console.
fn emitKey(sc: *const Softc, key: u8, mods: u8) void {
    if (key >= KEY_F1 and key <= KEY_F12) return wskbdutil.functionKey(key - KEY_F1 + 1);
    if (key >= KEY_INSERT and key <= KEY_UP) return wskbdutil.extendedKey(navtab[key - KEY_INSERT]);
    if (key == KEY_KP_ENTER) return cons.cnInput('\r');
    if (key == KEY_KP_SLASH) return cons.cnInput('/');
    if (key >= KEY_KP_1 and key <= KEY_KP_DOT and !sc.numlock) {
        // The keypad's other half: the same set 1 codes as the editing keys.
        return wskbdutil.extendedKey(trtab[key]);
    }

    const shift: bool = (mods & MOD_SHIFT) != 0;
    const ctrl: bool = (mods & MOD_CTRL) != 0;
    var ch: u8 = switch (key) {
        KEY_NONUS_BACKSLASH => if (shift) '|' else '\\',
        KEY_INTL1 => if (shift) '?' else '/',
        else => blk: {
            if (key >= trtab.len or trtab[key] == 0) return;
            const code: u8 = trtab[key];
            break :blk if (shift) keymap.shifted[code] else keymap.normal[code];
        },
    };
    if (sc.capslock and ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z'))) ch ^= 0x20;
    if (ctrl) ch = wskbdutil.controlChar(ch);
    if (ch == 0 and !ctrl) return;
    // Alt sends ESC first, as an xterm with metaSendsEscape does.
    if ((mods & MOD_ALT) != 0) cons.cnInput(0x1b);
    cons.cnInput(ch);
}

fn contains(keys: []const u8, key: u8) bool {
    for (keys) |k| {
        if (k == key) return true;
    }
    return false;
}

/// A report from the interrupt endpoint.
fn input(ctx: ?*anyopaque, data: []const u8) void {
    const sc: *Softc = @ptrCast(@alignCast(ctx.?));
    if (!sc.used or data.len < 3) return;
    var report: [8]u8 = @splat(0);
    const n: usize = @min(data.len, report.len);
    @memcpy(report[0..n], data[0..n]);
    const keys: []const u8 = report[2..];
    // Too many keys at once: the keyboard reports the error, not the keys.
    if (keys[0] == KEY_ERROR_ROLLOVER) return;
    const mods: u8 = report[0];

    for (keys) |key| {
        if (key == 0 or contains(sc.prev[2..], key)) continue;
        switch (key) {
            KEY_CAPSLOCK => sc.capslock = !sc.capslock,
            KEY_NUMLOCK => sc.numlock = !sc.numlock,
            else => {
                emitKey(sc, key, mods);
                sc.repeat_key = key;
                sc.repeat_at = arch.clock.tickCount() + REPEAT_DELAY;
            },
        }
    }
    if (sc.repeat_key != 0 and !contains(keys, sc.repeat_key)) sc.repeat_key = 0;
    sc.prev = report;
    sc.leds = ledState(sc);
}

/// Repeat the held key, and bring the LEDs up to date.
fn ukbdTick() void {
    const now: u64 = arch.clock.tickCount();
    for (&softc) |*sc| {
        if (!sc.used) continue;
        if (sc.repeat_key != 0 and now >= sc.repeat_at) {
            emitKey(sc, sc.repeat_key, sc.prev[0]);
            sc.repeat_at = now + REPEAT_RATE;
        }
        if (sc.leds != sc.leds_sent) {
            const led: [1]u8 = .{sc.leds};
            if (xhci.controlAsync(sc.dev, ledRequest(sc), led[0..])) sc.leds_sent = sc.leds;
        }
    }
}

fn ukbdRegister(_: ?*const anyopaque) callconv(.c) void {
    arch.clock.registerTickHandler(ukbdTick);
}

comptime {
    sysinit.SYSINIT("sysinit_ukbd", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_MIDDLE, ukbdRegister, null);
}
