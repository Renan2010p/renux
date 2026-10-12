// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Renux UEFI boot loader.
//
// The third stage of the Renux boot (FreeBSD's stand/efi/loader, written in
// Zig instead of C). The firmware loads this PE image as \EFI\BOOT\BOOTX64.EFI.
// The loader then:
//
//   1. finds the volume it came from and reads the kernel,
//   2. loads the kernel's ELF segments into a free physical region,
//   3. builds the Renux BootInfo (stand/arch/amd64/bootinfo.zig) and patches
//      the kernel's boot request with it,
//   4. builds page tables mapping the kernel at its link address, the HHDM and
//      an identity map,
//   5. leaves the firmware behind (ExitBootServices) and jumps to the kernel.

const std: type = @import("std");
const uefi: type = std.os.uefi;
const bootinfo: type = @import("bootinfo");

const kernel_path: [*:0]const u16 =
    std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\renux\\kernel");

const PT_LOAD: u32 = 1;
const KERNEL_STACK_PAGES: usize = 16;

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

/// Set once the firmware is gone: the console protocol is no longer valid.
var serial_only: bool = false;

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
        if (c == '\n') serialPut('\r');
        serialPut(c);
    }
    if (serial_only) return;
    const con = uefi.system_table.con_out orelse return;
    var buf: [128:0]u16 = undefined;
    if (s.len >= buf.len) return;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    _ = con.outputString(&buf) catch {};
}

fn hexDigit(n: u4) u8 {
    return if (n < 10) '0' + @as(u8, n) else 'a' + (@as(u8, n) - 10);
}

fn sayHex(v: u64) void {
    var b: [18]u8 = undefined;
    b[0] = '0';
    b[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast(60 - i * 4);
        b[2 + i] = hexDigit(@truncate(v >> shift));
    }
    say(&b);
}

fn sayDec(v: u64) void {
    var b: [24]u8 = undefined;
    var i: usize = b.len;
    var n: u64 = v;
    if (n == 0) {
        i -= 1;
        b[i] = '0';
    } else while (n != 0 and i > 0) {
        i -= 1;
        b[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    say(b[i..]);
}

// -- memory / paging helpers -------------------------------------------------

fn allocPages(bs: *uefi.tables.BootServices, n: usize) ?[]align(4096) uefi.Page {
    return bs.allocatePages(.any, .loader_data, n) catch null;
}

fn zeroPage(pa: u64) void {
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(pa)));
    var i: usize = 0;
    while (i < 4096) : (i += 1) p[i] = 0;
}

/// Map the 2 MiB page at virtual `virt` to physical `phys`, creating the
/// intermediate tables on demand.
fn map2M(bs: *uefi.tables.BootServices, pml4_pa: u64, virt: u64, phys: u64) void {
    const pml4: [*]u64 = @ptrFromInt(@as(usize, @intCast(pml4_pa)));
    const x4: usize = @intCast((virt >> 39) & 0x1ff);
    if ((pml4[x4] & 1) == 0) {
        const p = allocPages(bs, 1) orelse return;
        zeroPage(@intFromPtr(p.ptr));
        pml4[x4] = @intFromPtr(p.ptr) | 0x3;
    }
    const pdpt: [*]u64 = @ptrFromInt(@as(usize, @intCast(pml4[x4] & ~@as(u64, 0xfff))));
    const x3: usize = @intCast((virt >> 30) & 0x1ff);
    if ((pdpt[x3] & 1) == 0) {
        const p = allocPages(bs, 1) orelse return;
        zeroPage(@intFromPtr(p.ptr));
        pdpt[x3] = @intFromPtr(p.ptr) | 0x3;
    }
    const pd: [*]u64 = @ptrFromInt(@as(usize, @intCast(pdpt[x3] & ~@as(u64, 0xfff))));
    const x2: usize = @intCast((virt >> 21) & 0x1ff);
    pd[x2] = (phys & ~@as(u64, 0x1fffff)) | 0x83; // present | rw | 2MiB
}

fn align2M(v: u64) u64 {
    return (v + 0x1fffff) & ~@as(u64, 0x1fffff);
}

// -- the boot ----------------------------------------------------------------

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

    // Size through FileInfo (some firmwares return 0 from a zero-length read).
    var info_buf: [256]u8 align(8) = undefined;
    var size: u64 = 0;
    if (file.getInfoSize(.file)) |isz| {
        if (isz <= info_buf.len) {
            if (file.getInfo(.file, info_buf[0..isz])) |inf| {
                size = inf.file_size;
            } else |_| {}
        }
    } else |_| {}
    if (size == 0) size = file.readSize() catch 0;

    const img_pages = (size + 4095) / 4096;
    const img_mem = allocPages(bs, @intCast(img_pages)) orelse {
        say("loader: cannot stage the kernel\n");
        return error.OutOfResources;
    };
    const image: []u8 = @as([*]u8, @ptrCast(img_mem.ptr))[0..@intCast(size)];
    var got: usize = 0;
    while (got < image.len) {
        const want = @min(image.len - got, 1 << 20);
        const n = file.read(image[got .. got + want]) catch break;
        if (n == 0) break;
        got += n;
    }
    say("loader: read ");
    sayDec(got);
    say(" bytes\n");
    if (image.len < @sizeOf(Ehdr) or image[0] != 0x7f or image[1] != 'E' or
        image[2] != 'L' or image[3] != 'F')
    {
        say("loader: not an ELF\n");
        return error.InvalidParameter;
    }
    const eh: *const Ehdr = @ptrCast(@alignCast(image.ptr));

    // Physical span of the loadable segments.
    var lo: u64 = ~@as(u64, 0);
    var hi: u64 = 0;
    var vm_base: u64 = ~@as(u64, 0);
    var i: usize = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const off = eh.e_phoff + @as(u64, i) * eh.e_phentsize;
        if (off + @sizeOf(Phdr) > image.len) break;
        const ph: *const Phdr = @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(off))));
        if (ph.p_type != PT_LOAD) continue;
        if (ph.p_paddr < lo) lo = ph.p_paddr;
        if (ph.p_paddr + ph.p_memsz > hi) hi = ph.p_paddr + ph.p_memsz;
        if (ph.p_vaddr < vm_base) vm_base = ph.p_vaddr;
    }
    if (lo >= hi) {
        say("loader: no loadable segments\n");
        return error.InvalidParameter;
    }
    const span = hi - lo;

    // Place the image on a 2 MiB boundary so 2 MiB pages can map it.
    const region = allocPages(bs, @intCast((span + 0x200000 + 4095) / 4096)) orelse {
        say("loader: cannot allocate the kernel region\n");
        return error.OutOfResources;
    };
    const phys_base = align2M(@intFromPtr(region.ptr));

    i = 0;
    var segs: usize = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const off = eh.e_phoff + @as(u64, i) * eh.e_phentsize;
        if (off + @sizeOf(Phdr) > image.len) break;
        const ph: *const Phdr = @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(off))));
        if (ph.p_type != PT_LOAD) continue;
        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(phys_base + (ph.p_paddr - lo))));
        const src: [*]const u8 = @ptrCast(image.ptr + @as(usize, @intCast(ph.p_offset)));
        var k: usize = 0;
        while (k < ph.p_filesz) : (k += 1) dst[k] = src[k];
        while (k < ph.p_memsz) : (k += 1) dst[k] = 0;
        segs += 1;
    }
    say("loader: loaded ");
    sayDec(segs);
    say(" segments at ");
    sayHex(phys_base);
    say(" (entry ");
    sayHex(eh.e_entry);
    say(")\n");

    // How far physical memory goes, for the identity and HHDM maps.
    const map = try getMap(bs);
    var mem_max: u64 = 0;
    var it = map.slice.iterator();
    while (it.next()) |d| {
        const end = d.physical_start + d.number_of_pages * 4096;
        if (end > mem_max) mem_max = end;
    }
    mem_max = align2M(mem_max);

    // The framebuffer is MMIO, usually above RAM: make sure the maps cover it.
    var fb_count: u64 = 0;
    var fb_store: [1]bootinfo.Framebuffer = undefined;
    if (queryFb(bs)) |f| {
        fb_store[0] = f;
        fb_count = 1;
        const pbase = @intFromPtr(f.address.?) - bootinfo.HHDM_OFFSET;
        const end = pbase + f.pitch * f.height;
        if (end > mem_max) mem_max = align2M(end);
        say("loader: framebuffer ");
        sayDec(f.width);
        say("x");
        sayDec(f.height);
        say("\n");
    }

    // Page tables: identity (for us and the early kernel), the higher-half
    // HHDM the kernel uses for physical access, and the kernel image at its
    // link address.
    const pml4 = allocPages(bs, 1) orelse return error.OutOfResources;
    zeroPage(@intFromPtr(pml4.ptr));
    const pml4_pa: u64 = @intFromPtr(pml4.ptr);

    var pa: u64 = 0;
    while (pa < mem_max) : (pa += 0x200000) {
        map2M(bs, pml4_pa, pa, pa); // identity
        map2M(bs, pml4_pa, bootinfo.HHDM_OFFSET + pa, pa); // HHDM
    }
    var k: u64 = 0;
    while (k < span) : (k += 0x200000) {
        map2M(bs, pml4_pa, vm_base + k, phys_base + k);
    }
    say("loader: page tables ready\n");

    // A fresh stack for the kernel, and the BootInfo's memory-map array. Both
    // are allocated before the final map query, so nothing invalidates the map
    // key ExitBootServices needs.
    const stack = allocPages(bs, KERNEL_STACK_PAGES) orelse return error.OutOfResources;
    // Put the kernel's boot stack in the HHDM. Process page maps copy the
    // kernel half (including the HHDM) but not the low identity map, so a stack
    // in low memory would vanish the moment the scheduler switches to a
    // process and back.
    // The SysV ABI expects RSP % 16 == 8 at function entry (as after a `call`).
    // We enter the kernel with `jmp`, so bias the stack by 8.
    const stack_top: u64 = ((@intFromPtr(stack.ptr) + bootinfo.HHDM_OFFSET + KERNEL_STACK_PAGES * 4096) & ~@as(u64, 0xf)) - 8;
    const entries = allocPages(bs, 1) orelse return error.OutOfResources;
    // The loader runs under the firmware's page tables, which have no HHDM, so
    // it writes the boot info through the identity alias but hands the kernel
    // the HHDM address of the same physical memory (which every process page
    // map keeps).
    const mm: [*]bootinfo.MemmapEntry = @ptrCast(@alignCast(entries.ptr));

    var bi: bootinfo.BootInfo = .{
        .magic = bootinfo.MAGIC,
        .revision = bootinfo.revision,
        .hhdm = bootinfo.HHDM_OFFSET,
        .memmap = @ptrFromInt(@intFromPtr(entries.ptr) + bootinfo.HHDM_OFFSET),
        .memmap_count = 0,
        .modules = null,
        .module_count = 0,
        .framebuffers = @ptrFromInt(@intFromPtr(&fb_store) + bootinfo.HHDM_OFFSET),
        .framebuffer_count = fb_count,
        .cmdline = null,
        .physical_base = phys_base - lo,
        .virtual_base = vm_base,
    };

    // Patch the kernel's boot request with the BootInfo.
    const want = bootinfo.requestId();
    const scan: [*]u8 = @ptrFromInt(@as(usize, @intCast(phys_base)));
    var found: ?[*]u8 = null;
    var j: usize = 0;
    while (j + 32 <= span) : (j += 8) {
        const w: *const [4]u64 = @ptrCast(@alignCast(scan + j));
        if (w[0] == want[0] and w[1] == want[1] and w[2] == want[2] and w[3] == want[3]) {
            found = scan + j;
            break;
        }
    }
    if (found) |req| {
        const slot: *u64 = @ptrCast(@alignCast(req + bootinfo.Request.response_offset));
        slot.* = @intFromPtr(&bi) + bootinfo.HHDM_OFFSET;
        say("loader: patched the boot request\n");
    } else {
        say("loader: boot request not found\n");
        return error.NotFound;
    }

    // Hand over. ExitBootServices only succeeds with the very latest memory
    // map key, and the map can change under us, so retry if it fails.
    say("loader: leaving the firmware\n");
    serial_only = true;
    var exited: bool = false;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const m = getMap(bs) catch break;
        var c2: u64 = 0;
        var it3 = m.slice.iterator();
        while (it3.next()) |d| {
            if (c2 >= 512) break;
            mm[c2] = .{
                .base = d.physical_start,
                .length = d.number_of_pages * 4096,
                .type = if (d.type == .conventional_memory) bootinfo.MemmapEntry.USABLE else bootinfo.MemmapEntry.RESERVED,
            };
            c2 += 1;
        }
        bi.memmap_count = c2;
        bs.exitBootServices(uefi.handle, m.slice.info.key) catch continue;
        exited = true;
        break;
    }
    if (!exited) {
        say("loader: ExitBootServices failed\n");
        return error.Unexpected;
    }

    jump(eh.e_entry, pml4_pa, stack_top);
}

/// Ask the firmware for its graphical output and describe it in BootInfo form.
fn queryFb(bs: *uefi.tables.BootServices) ?bootinfo.Framebuffer {
    const gop = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return null;
    const g = gop orelse return null;
    const inf = g.mode.info;
    var rs: u8 = 8;
    var gs: u8 = 8;
    var bs_: u8 = 8;
    var rsh: u8 = 16;
    var gsh: u8 = 8;
    var bsh: u8 = 0;
    switch (inf.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => {},
        .red_green_blue_reserved_8_bit_per_color => {
            rsh = 0;
            gsh = 8;
            bsh = 16;
        },
        .bit_mask => {
            const pm = inf.pixel_information;
            rsh = @intCast(@ctz(pm.red_mask));
            gsh = @intCast(@ctz(pm.green_mask));
            bsh = @intCast(@ctz(pm.blue_mask));
            rs = @intCast(@popCount(pm.red_mask));
            gs = @intCast(@popCount(pm.green_mask));
            bs_ = @intCast(@popCount(pm.blue_mask));
        },
        else => {},
    }
    const bpp: u64 = rs + gs + bs_;
    return .{
        .address = @ptrFromInt(g.mode.frame_buffer_base + bootinfo.HHDM_OFFSET),
        .width = inf.horizontal_resolution,
        .height = inf.vertical_resolution,
        .pitch = @as(u64, inf.pixels_per_scan_line) * (bpp / 8),
        .bpp = @intCast(bpp),
        .memory_model = 1,
        .red_mask_size = rs,
        .red_mask_shift = rsh,
        .green_mask_size = gs,
        .green_mask_shift = gsh,
        .blue_mask_size = bs_,
        .blue_mask_shift = bsh,
    };
}

/// The physical memory map, as the firmware reports it.
const Map = struct {
    slice: uefi.tables.MemoryMapSlice,
};

fn getMap(bs: *uefi.tables.BootServices) !Map {
    const info = try bs.getMemoryMapInfo();
    // The map can grow between queries, so leave a little room.
    const cap_bytes = (info.len + 8) * info.descriptor_size;
    const pages = (cap_bytes + 4095) / 4096 + 1;
    const mem = bs.allocatePages(.any, .loader_data, pages) catch return error.OutOfResources;
    const buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 =
        @alignCast(@as([*]u8, @ptrCast(mem.ptr))[0 .. pages * 4096]);
    const slice = try bs.getMemoryMap(buf);
    return .{ .slice = slice };
}

/// Leave the firmware behind and enter the kernel at `entry`, with CR3 set to
/// the page tables we built and a fresh stack.
fn jump(entry: u64, cr3: u64, stack: u64) noreturn {
    asm volatile (
        \\ mov %[sp], %%rsp
        \\ mov %[cr3], %%cr3
        \\ jmp *%[entry]
        :
        : [sp] "r" (stack),
          [cr3] "r" (cr3),
          [entry] "r" (entry),
        : .{ .memory = true });
    unreachable;
}
