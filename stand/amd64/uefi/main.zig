// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Renux UEFI boot loader.
//
// The third stage of the Renux boot (FreeBSD's stand/efi/loader, written in
// Zig instead of C). The firmware loads this PE image as \EFI\BOOT\BOOTX64.EFI;
// it finds the volume it came from, reads the kernel, loads its ELF segments,
// builds the Renux BootInfo (stand/arch/amd64/bootinfo.zig) and patches the
// kernel's boot request with it.

const std: type = @import("std");
const uefi: type = std.os.uefi;
const bootinfo: type = @import("bootinfo");

const kernel_path: [*:0]const u16 =
    std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\renux\\kernel");

const PT_LOAD: u32 = 1;

const Ehdr: type = extern struct {
    ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Phdr: type = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

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

fn say(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            serialPut('\r');
        }
        serialPut(c);
    }
    const con = uefi.system_table.con_out orelse return;
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

fn sayDec(v: u64) void {
    var b: [24]u8 = undefined;
    say(dec(&b, v));
}

/// Count how many bytes of `data` can be read without faulting is not possible
/// here; the file was read through UEFI, so the slice is valid.
fn readWhole(file: *uefi.protocol.File, bs: *uefi.tables.BootServices, size: usize) ?[]u8 {
    const pages = (size + 4095) / 4096;
    const mem = bs.allocatePages(.any, .loader_data, pages) catch {
        say("loader: allocatePages failed\n");
        return null;
    };
    const buf: [*]u8 = @ptrCast(mem.ptr);
    var got: usize = 0;
    while (got < size) {
        // Read in bounded chunks: some firmware File.Read implementations
        // reject very large requests.
        const want = @min(size - got, 1 << 20);
        const n = file.read(buf[got .. got + want]) catch {
            say("loader: read error\n");
            return null;
        };
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

pub fn main() uefi.Error!void {
    serialInit();
    const bs = uefi.system_table.boot_services orelse return error.Unexpected;

    say("Renux loader\n");

    const li = try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) orelse
        return error.Unexpected;
    const device = li.device_handle orelse return error.Unexpected;
    const fs = try bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) orelse
        return error.Unexpected;
    const root = try fs.openVolume();

    const file = root.open(kernel_path, .read, .{}) catch {
        say("loader: kernel not found\n");
        return error.NotFound;
    };
    defer file.close() catch {};

    var info_buf: [256]u8 align(8) = undefined;
    var size: u64 = 0;
    if (file.getInfoSize(.file)) |isz| {
        if (isz <= info_buf.len) {
            if (file.getInfo(.file, info_buf[0..isz])) |inf| {
                size = inf.file_size;
            } else |_| {}
        }
    } else |_| {}
    if (size == 0) {
        size = file.readSize() catch 0;
    }
    say("loader: kernel size ");
    sayDec(size);
    say(" bytes\n");
    const image = readWhole(file, bs, size) orelse {
        say("loader: cannot read kernel\n");
        return error.OutOfResources;
    };
    say("loader: read ");
    sayDec(image.len);
    say(" bytes\n");

    if (image.len < @sizeOf(Ehdr) or image[0] != 0x7f or image[1] != 'E' or image[2] != 'L' or image[3] != 'F') {
        say("loader: not an ELF\n");
        return error.InvalidParameter;
    }
    const eh: *const Ehdr = @ptrCast(@alignCast(image.ptr));

    // Find the physical span of the loadable segments, allocate one region for
    // it anywhere in memory and place the segments so their relative layout is
    // preserved (the kernel is linked at a fixed virtual base; the loader picks
    // the physical base).
    var lo: u64 = ~@as(u64, 0);
    var hi: u64 = 0;
    var i: usize = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const off = eh.e_phoff + @as(u64, i) * eh.e_phentsize;
        if (off + @sizeOf(Phdr) > image.len) break;
        const ph: *const Phdr = @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(off))));
        if (ph.p_type != PT_LOAD) continue;
        if (ph.p_paddr < lo) lo = ph.p_paddr;
        if (ph.p_paddr + ph.p_memsz > hi) hi = ph.p_paddr + ph.p_memsz;
    }
    if (lo >= hi) {
        say("loader: no loadable segments\n");
        return error.InvalidParameter;
    }
    const span = hi - lo;
    const region = bs.allocatePages(.any, .loader_data, (span + 4095) / 4096) catch {
        say("loader: cannot allocate the kernel region\n");
        return error.OutOfResources;
    };
    const base: u64 = @intFromPtr(region.ptr);

    var segs: usize = 0;
    i = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const off = eh.e_phoff + @as(u64, i) * eh.e_phentsize;
        if (off + @sizeOf(Phdr) > image.len) break;
        const ph: *const Phdr = @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(off))));
        if (ph.p_type != PT_LOAD) continue;
        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(base + (ph.p_paddr - lo))));
        const src: [*]const u8 = @ptrCast(image.ptr + @as(usize, @intCast(ph.p_offset)));
        var k: usize = 0;
        while (k < ph.p_filesz) : (k += 1) {
            dst[k] = src[k];
        }
        while (k < ph.p_memsz) : (k += 1) {
            dst[k] = 0;
        }
        segs += 1;
    }
    say("loader: loaded ");
    sayDec(segs);
    say(" segments at ");
    sayDec(base);
    say(" (entry ");
    sayDec(eh.e_entry);
    say(")\n");

    // Patch the kernel's boot request with the BootInfo.
    const want = bootinfo.requestId();
    const scan: [*]u8 = @ptrFromInt(@as(usize, @intCast(base)));
    var found: ?[*]u8 = null;
    var j: usize = 0;
    while (j + 32 <= span) : (j += 8) {
        const w: *const [4]u64 = @ptrCast(@alignCast(scan + j));
        if (w[0] == want[0] and w[1] == want[1] and w[2] == want[2] and w[3] == want[3]) {
            found = scan + j;
            break;
        }
    }
    // The BootInfo the kernel will read. It lives in the loader's image for
    // now; the memory map and framebuffer are filled by the next milestone.
    var bi: bootinfo.BootInfo = .{
        .magic = bootinfo.MAGIC,
        .revision = bootinfo.revision,
        .hhdm = bootinfo.HHDM_OFFSET,
        .memmap = null,
        .memmap_count = 0,
        .modules = null,
        .module_count = 0,
        .framebuffers = null,
        .framebuffer_count = 0,
        .cmdline = null,
        .physical_base = base - lo,
        .virtual_base = 0,
    };

    if (found) |req| {
        const slot: *u64 = @ptrCast(@alignCast(req + bootinfo.Request.response_offset));
        slot.* = @intFromPtr(&bi);
        say("loader: patched the boot request\n");
    }
}
