// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// USB device enumeration.
//
// The Zig counterpart of FreeBSD's sys/dev/usb/usb_device.c (usb_alloc_device
// and usb_probe_and_attach), reduced to one configuration: once the host
// controller has given a device its address, read the device descriptor
// (fixing the default endpoint's packet size), the product strings and the
// first configuration, select it, and offer each interface to the class
// drivers. The boot log reads like FreeBSD's:
//
//   ugen0.1: <CASUE USB KB> at usbus0
//   ukbd0: <CASUE USB KB, class 0/0, rev 1.10/0.01, addr 1> on usbus0

const prf: type = @import("../../core/subr_prf.zig");
const xhci: type = @import("controller/xhci.zig");
const usb: type = @import("usb.zig");
const ukbd: type = @import("input/ukbd.zig");

/// What the class drivers are told about the device.
pub const Info: type = struct {
    desc: usb.DeviceDescriptor,
    /// "<manufacturer> <product>", or the vendor and product ids.
    name: [96]u8 = undefined,
    name_len: usize = 0,

    pub fn nameSlice(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }

    fn append(self: *Info, s: []const u8) void {
        for (s) |c| {
            if (self.name_len < self.name.len) {
                self.name[self.name_len] = c;
                self.name_len += 1;
            }
        }
    }

    fn appendHex(self: *Info, v: u16) void {
        self.append("0x");
        var shift: u5 = 12;
        while (true) : (shift -= 4) {
            self.append(&[_]u8{"0123456789abcdef"[(v >> @intCast(shift)) & 0xf]});
            if (shift == 0) break;
        }
    }
};

fn getDescriptor(dev: *xhci.Device, dtype: u8, index: u8, lang: u16, buf: []u8) ?usize {
    return xhci.control(dev, .{
        .bmRequestType = usb.UT_READ_DEVICE,
        .bRequest = usb.UR_GET_DESCRIPTOR,
        .wValue = (@as(u16, dtype) << 8) | index,
        .wIndex = lang,
        .wLength = @intCast(buf.len),
    }, buf);
}

/// Append string descriptor `index` to `info.name`, as ASCII (anything else
/// becomes '?'). Returns false when the device has no such string.
fn appendString(dev: *xhci.Device, info: *Info, index: u8, lang: u16) bool {
    if (index == 0) return false;
    var buf: [255]u8 = undefined;
    const n: usize = getDescriptor(dev, usb.UDESC_STRING, index, lang, buf[0..]) orelse return false;
    if (n < 4 or buf[1] != usb.UDESC_STRING) return false;
    const len: usize = @min(n, buf[0]);
    const start: usize = info.name_len;
    var i: usize = 2;
    while (i + 1 < len) : (i += 2) {
        const c: u16 = @as(u16, buf[i]) | (@as(u16, buf[i + 1]) << 8);
        info.append(&[_]u8{if (c >= 0x20 and c < 0x7f) @intCast(c) else '?'});
    }
    // Trim the trailing blanks some devices pad their strings with.
    while (info.name_len > start and info.name[info.name_len - 1] == ' ') info.name_len -= 1;
    return true;
}

fn deviceName(dev: *xhci.Device, info: *Info) void {
    var langs: [4]u8 = undefined;
    const lang: u16 = blk: {
        const n: usize = getDescriptor(dev, usb.UDESC_STRING, 0, 0, langs[0..]) orelse break :blk 0;
        if (n < 4) break :blk 0;
        break :blk @as(u16, langs[2]) | (@as(u16, langs[3]) << 8);
    };
    if (lang != 0) {
        const before: usize = info.name_len;
        if (appendString(dev, info, info.desc.iManufacturer, lang)) info.append(" ");
        if (!appendString(dev, info, info.desc.iProduct, lang)) info.name_len = before;
        while (info.name_len > 0 and info.name[info.name_len - 1] == ' ') info.name_len -= 1;
    }
    if (info.name_len == 0) {
        info.append("vendor ");
        info.appendHex(info.desc.idVendor);
        info.append(" product ");
        info.appendHex(info.desc.idProduct);
    }
}

/// Walk the configuration descriptor and offer every interface (first
/// alternate setting) with its endpoints to the class drivers.
fn probeInterfaces(dev: *xhci.Device, info: *const Info, cfg: []const u8) void {
    var off: usize = 0;
    while (off + 2 <= cfg.len) {
        const len: usize = cfg[off];
        if (len < 2 or off + len > cfg.len) break;
        if (cfg[off + 1] == usb.UDESC_INTERFACE and len >= @sizeOf(usb.InterfaceDescriptor)) {
            const id: usb.InterfaceDescriptor = @as(*align(1) const usb.InterfaceDescriptor, @ptrCast(cfg[off..].ptr)).*;
            if (id.bAlternateSetting == 0 and ukbd.probe(&id)) {
                if (findInterruptIn(cfg[off + len ..])) |ep| {
                    if (ukbd.attach(dev, info, &id, &ep)) return; // one driver per device
                }
            }
        }
        off += len;
    }
}

/// The first interrupt IN endpoint before the next interface descriptor.
fn findInterruptIn(rest: []const u8) ?usb.EndpointDescriptor {
    var off: usize = 0;
    while (off + 2 <= rest.len) {
        const len: usize = rest[off];
        if (len < 2 or off + len > rest.len) break;
        if (rest[off + 1] == usb.UDESC_INTERFACE) break;
        if (rest[off + 1] == usb.UDESC_ENDPOINT and len >= @sizeOf(usb.EndpointDescriptor)) {
            const ep: usb.EndpointDescriptor = @as(*align(1) const usb.EndpointDescriptor, @ptrCast(rest[off..].ptr)).*;
            if ((ep.bEndpointAddress & usb.UE_DIR_IN) != 0 and (ep.bmAttributes & usb.UE_XFERTYPE) == usb.UE_INTERRUPT) return ep;
        }
        off += len;
    }
    return null;
}

/// Read the device's descriptors, configure it and attach its drivers.
/// Returns false when the device does not answer.
pub fn enumerate(dev: *xhci.Device) bool {
    var head: [8]u8 = undefined;
    const n: usize = getDescriptor(dev, usb.UDESC_DEVICE, 0, 0, head[0..]) orelse return false;
    if (n < 8) return false;
    var mps: u32 = head[7];
    if (dev.speed == 4) mps = @as(u32, 1) << @intCast(@min(mps, 15)); // SuperSpeed gives an exponent
    if (mps != 0 and mps != dev.mps0 and !xhci.setMaxPacket0(dev, mps)) return false;

    var raw: [@sizeOf(usb.DeviceDescriptor)]u8 = undefined;
    if ((getDescriptor(dev, usb.UDESC_DEVICE, 0, 0, raw[0..]) orelse 0) != raw.len) return false;
    var info: Info = .{ .desc = @as(*align(1) const usb.DeviceDescriptor, @ptrCast(&raw)).* };
    deviceName(dev, &info);
    prf.printf("ugen%u.%u: <%s> at %s\n", .{ dev.busUnit(), dev.address(), info.nameSlice(), dev.busName() });

    var cfg_head: [@sizeOf(usb.ConfigDescriptor)]u8 = undefined;
    if ((getDescriptor(dev, usb.UDESC_CONFIG, 0, 0, cfg_head[0..]) orelse 0) != cfg_head.len) return false;
    const cd: usb.ConfigDescriptor = @as(*align(1) const usb.ConfigDescriptor, @ptrCast(&cfg_head)).*;
    var cfg: [1024]u8 = undefined;
    const total: usize = @min(@as(usize, cd.wTotalLength), cfg.len);
    const got: usize = getDescriptor(dev, usb.UDESC_CONFIG, 0, 0, cfg[0..total]) orelse return false;

    var none: [0]u8 = .{};
    _ = xhci.control(dev, .{
        .bmRequestType = usb.UT_WRITE_DEVICE,
        .bRequest = usb.UR_SET_CONFIG,
        .wValue = cd.bConfigurationValue,
        .wIndex = 0,
        .wLength = 0,
    }, none[0..]) orelse return false;

    probeInterfaces(dev, &info, cfg[0..got]);
    return true;
}
