// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Renux UEFI boot loader.
//
// The counterpart of FreeBSD's stand/efi/loader (main.c, bootinfo.c,
// copy.c, the ELF loader in stand/common/load_elf.c), written in Zig. The
// firmware loads it as \EFI\BOOT\BOOTX64.EFI. It then:
//
//   1. reports itself and the firmware, and reads /boot/defaults/loader.conf
//      and /boot/loader.conf;
//   2. shows the boot menu (stand/common/menu.zig) with its autoboot
//      countdown, or the OK prompt (stand/common/interp.zig);
//   3. loads the chosen kernel's ELF segments, printing each one as FreeBSD's
//      loader does ("text=0x... data=0x...+0x...");
//   4. builds the Renux BootInfo (stand/arch/amd64/bootinfo.zig), with the
//      memory map, the framebuffer and the boot flags (-s, -v, console=...)
//      on the kernel command line, and patches the kernel's boot request;
//   5. builds page tables (identity, HHDM, the kernel at its link address),
//      leaves the firmware (ExitBootServices) and jumps to the kernel.
//
// Everything printed describes what the loader actually did.

const std: type = @import("std");
const uefi: type = std.os.uefi;
const bootinfo: type = @import("bootinfo");
const md: type = @import("loader_md");
const platform: type = @import("platform");
const common: type = @import("common");
const env: type = common.env;
const menu: type = common.menu;
const interp: type = common.interp;

/// Loader version, printed in the banner.
const REVISION: []const u8 = "0.1";

const PT_LOAD: u32 = 1;
const PF_X: u32 = 1;
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

fn bs() *uefi.tables.BootServices {
    return uefi.system_table.boot_services.?;
}

fn allocPages(n: usize) ?[]align(4096) uefi.Page {
    return bs().allocatePages(.any, .loader_data, n) catch null;
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) & ~(a - 1);
}

fn zeroPage(pa: u64) void {
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(pa)));
    @memset(p[0..4096], 0);
}

// -- banner ------------------------------------------------------------------

/// Print the path the firmware loaded us from (the file path node of the
/// loaded image's device path).
fn printLoadPath(li: *const uefi.protocol.LoadedImage) void {
    var node: [*]const u8 = @ptrCast(li.file_path);
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        const typ: u8 = node[0];
        const sub: u8 = node[1];
        const len: u16 = @as(u16, node[2]) | (@as(u16, node[3]) << 8);
        if (typ == 0x7f or len < 4) break;
        if (typ == 4 and sub == 4) {
            // MEDIA_FILEPATH_DP: a UCS-2 path.
            const chars: usize = (len - 4) / 2;
            var b: [128]u8 = undefined;
            var n: usize = 0;
            var i: usize = 0;
            while (i < chars and n < b.len) : (i += 1) {
                const c: u16 = @as(u16, node[4 + 2 * i]) | (@as(u16, node[5 + 2 * i]) << 8);
                if (c == 0) break;
                b[n] = if (c < 0x80) @intCast(c) else '?';
                n += 1;
            }
            platform.print(b[0..n]);
        }
        node += len;
    }
}

fn banner() void {
    platform.print("Consoles: EFI console\n");
    platform.printf("Renux/amd64 EFI loader, Revision {s}\n\n", .{REVISION});
    if (bs().handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) |li| {
        platform.printf("   Image base: 0x{x}\n", .{@intFromPtr(li.image_base)});
        platform.print("   EFI version: ");
        platform.printEfiVersion();
        platform.print("\n   EFI Firmware: ");
        platform.printFirmware();
        platform.print("\n   Load Path: ");
        printLoadPath(li);
        platform.print("\n\n");
    }
}

// -- kernel command line -----------------------------------------------------

var cmdline_buf: [256]u8 = undefined;

/// The kernel arguments for the chosen options: FreeBSD's boot flags plus the
/// console selection.
fn buildCmdline() []const u8 {
    var n: usize = 0;
    const parts = [_]struct { on: bool, text: []const u8 }{
        .{ .on = env.isYes("boot_single"), .text = "-s " },
        .{ .on = env.isYes("boot_verbose"), .text = "-v " },
    };
    for (parts) |p| {
        if (p.on) {
            @memcpy(cmdline_buf[n .. n + p.text.len], p.text);
            n += p.text.len;
        }
    }
    if (env.get("console")) |c| {
        const s = std.fmt.bufPrint(cmdline_buf[n..], "console={s}", .{c}) catch "";
        // Spaces separate kernel arguments; the console list uses commas.
        for (cmdline_buf[n .. n + s.len]) |*ch| {
            if (ch.* == ' ') ch.* = ',';
        }
        n += s.len;
    }
    return std.mem.trimEnd(u8, cmdline_buf[0..n], " ");
}

// -- the boot ----------------------------------------------------------------

pub fn main() uefi.Error!void {
    // The firmware's watchdog would reset us while the menu waits.
    _ = bs().setWatchdogTimer(0, 0, null) catch {};
    platform.consInit();

    if (!platform.openBootVolume()) {
        platform.print("loader: cannot open the boot volume\n");
        return error.NotFound;
    }
    banner();
    if (!env.loadConf("/boot/defaults/loader.conf")) {
        // Built-in defaults, so the loader still works without the file.
        _ = env.set("autoboot_delay", "10");
        _ = env.set("kernel", "kernel");
        _ = env.set("kernels", "kernel kernel.old");
    }
    _ = env.loadConf("/boot/loader.conf");
    _ = env.loadConf("/boot/loader.conf.local");

    // FreeBSD's flow: the menu (unless beastie_disable), else an autoboot
    // countdown at the prompt; booting failures land on the prompt.
    var use_menu: bool = !env.isYes("beastie_disable");
    var go_prompt: bool = false;
    if (!use_menu) {
        go_prompt = !interp.autoboot(env.getNumber("autoboot_delay", 10));
    }
    while (true) {
        if (use_menu and !go_prompt) {
            const a = menu.run();
            menu.finish();
            if (a == .prompt) go_prompt = true;
        }
        if (go_prompt) {
            if (interp.run() == .menu) {
                go_prompt = false;
                use_menu = true;
                continue;
            }
        }
        bootKernel() catch {};
        // Booting failed: the reason was printed; fall back to the prompt.
        go_prompt = true;
    }
}

fn bootKernel() !void {
    var pbuf: [128]u8 = undefined;
    const kname: []const u8 = env.get("kernel") orelse "kernel";
    const path: []const u8 = menu.kernelPath(&pbuf, kname) orelse return error.InvalidParameter;

    platform.print("Loading kernel...\n");
    const image: []u8 = platform.readFile(path) orelse {
        platform.printf("can't load '{s}'\n", .{kname});
        return error.NotFound;
    };
    if (image.len < @sizeOf(Ehdr) or !std.mem.eql(u8, image[0..4], "\x7fELF")) {
        platform.printf("{s}: not an ELF file\n", .{path});
        return error.InvalidParameter;
    }
    const eh: *const Ehdr = @ptrCast(@alignCast(image.ptr));

    // Physical span of the loadable segments.
    var lo: u64 = ~@as(u64, 0);
    var hi: u64 = 0;
    var vm_base: u64 = ~@as(u64, 0);
    var i: usize = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const ph: *const Phdr = phdr(image, eh, i) orelse break;
        if (ph.p_type != PT_LOAD) continue;
        lo = @min(lo, ph.p_paddr);
        hi = @max(hi, ph.p_paddr + ph.p_memsz);
        vm_base = @min(vm_base, ph.p_vaddr);
    }
    if (lo >= hi) {
        platform.printf("{s}: no loadable segments\n", .{path});
        return error.InvalidParameter;
    }
    const span: u64 = hi - lo;

    // Place the image on a 2 MiB boundary so 2 MiB pages can map it.
    const region = allocPages(@intCast((span + 0x200000 + 4095) / 4096)) orelse {
        platform.print("loader: not enough memory for the kernel\n");
        return error.OutOfResources;
    };
    const phys_base: u64 = alignUp(@intFromPtr(region.ptr), md.elf64.KERNEL_ALIGN);

    // Copy the segments, reporting each one as FreeBSD's load_elf.c does.
    platform.print(path);
    i = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const ph: *const Phdr = phdr(image, eh, i) orelse break;
        if (ph.p_type != PT_LOAD) continue;
        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(phys_base + (ph.p_paddr - lo))));
        const fsz: usize = @intCast(ph.p_filesz);
        const msz: usize = @intCast(ph.p_memsz);
        @memcpy(dst[0..fsz], image[@intCast(ph.p_offset)..][0..fsz]);
        @memset(dst[fsz..msz], 0);
        if ((ph.p_flags & PF_X) != 0) {
            platform.printf(" text=0x{x}", .{ph.p_filesz});
        } else {
            platform.printf(" data=0x{x}", .{ph.p_filesz});
            if (ph.p_memsz > ph.p_filesz) platform.printf("+0x{x}", .{ph.p_memsz - ph.p_filesz});
        }
    }
    platform.print("\n");
    const entry: u64 = eh.e_entry;

    // The staged file is no longer needed: give it back to the firmware so it
    // ends up as free memory for the kernel.
    _ = bs().freePages(@alignCast(@as([*]uefi.Page, @ptrCast(image.ptr))[0 .. (image.len + 4095) / 4096 + 1])) catch {};

    try handoff(entry, phys_base, lo, vm_base, span);
}

fn phdr(image: []const u8, eh: *const Ehdr, i: usize) ?*const Phdr {
    const off: u64 = eh.e_phoff + @as(u64, i) * eh.e_phentsize;
    if (off + @sizeOf(Phdr) > image.len) return null;
    return @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(off))));
}

/// Everything the kernel reads after the firmware is gone, in one page of
/// loader memory (which the kernel never reuses): the BootInfo, the
/// framebuffer description and the command line.
const Handoff: type = extern struct {
    bi: bootinfo.BootInfo,
    fb: bootinfo.Framebuffer,
    cmdline: [256]u8,
};

fn handoff(entry: u64, phys_base: u64, lo: u64, vm_base: u64, span: u64) !void {
    const hpage = allocPages(1) orelse return error.OutOfResources;
    zeroPage(@intFromPtr(hpage.ptr));
    const h: *Handoff = @ptrCast(@alignCast(hpage.ptr));
    const H: u64 = bootinfo.HHDM_OFFSET;

    // How far physical memory goes, for the identity and HHDM maps.
    var mem_max: u64 = 0;
    {
        const m = try getMap();
        var it = m.iterator();
        while (it.next()) |d| mem_max = @max(mem_max, d.physical_start + d.number_of_pages * 4096);
    }
    mem_max = alignUp(mem_max, md.elf64.KERNEL_ALIGN);

    // The framebuffer, reported the way FreeBSD's loader does.
    var fb_count: u64 = 0;
    if (queryFb()) |f| {
        h.fb = f.fb;
        fb_count = 1;
        const end: u64 = f.phys + f.fb.pitch * f.fb.height;
        if (end > mem_max) mem_max = alignUp(end, md.elf64.KERNEL_ALIGN);
        platform.print("EFI framebuffer information:\n");
        platform.printf("addr, size     0x{x}, 0x{x}\n", .{ f.phys, f.fb.pitch * f.fb.height });
        platform.printf("dimensions     {d} x {d}\n", .{ f.fb.width, f.fb.height });
        platform.printf("stride         {d}\n", .{f.fb.pitch / (f.fb.bpp / 8)});
        platform.printf("masks          0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}\n", .{ f.masks[0], f.masks[1], f.masks[2], f.masks[3] });
    }

    const cl: []const u8 = buildCmdline();
    @memcpy(h.cmdline[0..cl.len], cl);
    h.cmdline[cl.len] = 0;

    // The kernel's page tables (machine dependent: arch/<machine>).
    const pml4_pa: u64 = try md.elf64.buildPageTables(mem_max, H, vm_base, phys_base, span);

    // The kernel's boot stack lives in the HHDM: process page maps copy the
    // kernel half but not the identity map. The SysV ABI expects RSP % 16 == 8
    // at entry (as after a call); we enter with jmp, so bias by 8.
    const stack = allocPages(KERNEL_STACK_PAGES) orelse return error.OutOfResources;
    const stack_top: u64 = ((@intFromPtr(stack.ptr) + H + KERNEL_STACK_PAGES * 4096) & ~@as(u64, 0xf)) - 8;
    const entries = allocPages(8) orelse return error.OutOfResources;
    const mm: [*]bootinfo.MemmapEntry = @ptrCast(@alignCast(entries.ptr));
    const mm_max: usize = 8 * 4096 / @sizeOf(bootinfo.MemmapEntry);

    // The loader writes through the identity alias (it runs on the firmware's
    // page tables) and hands the kernel HHDM addresses of the same memory.
    h.bi = .{
        .magic = bootinfo.MAGIC,
        .revision = bootinfo.revision,
        .hhdm = H,
        .memmap = @ptrFromInt(@intFromPtr(entries.ptr) + H),
        .memmap_count = 0,
        .modules = null,
        .module_count = 0,
        .framebuffers = @ptrFromInt(@intFromPtr(&h.fb) + H),
        .framebuffer_count = fb_count,
        .cmdline = @ptrFromInt(@intFromPtr(&h.cmdline) + H),
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
    const req: [*]u8 = found orelse {
        platform.print("loader: the kernel has no Renux boot request\n");
        return error.NotFound;
    };
    const slot: *u64 = @ptrCast(@alignCast(req + bootinfo.Request.response_offset));
    slot.* = @intFromPtr(&h.bi) + H;

    platform.printf("Start @ 0x{x} ...\n", .{entry});

    // ExitBootServices only succeeds with the latest map key, and the map can
    // change under us, so retry. Nothing may be printed past this point.
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const m = getMap() catch break;
        var c: usize = 0;
        var it = m.iterator();
        while (it.next()) |d| {
            if (c >= mm_max) break;
            mm[c] = .{
                .base = d.physical_start,
                .length = d.number_of_pages * 4096,
                .type = memType(d.type),
            };
            c += 1;
        }
        h.bi.memmap_count = c;
        bs().exitBootServices(uefi.handle, m.info.key) catch continue;
        md.tramp.tramp(entry, pml4_pa, stack_top);
    }
    platform.print("loader: ExitBootServices failed\n");
    return error.Unexpected;
}

/// Translate a UEFI memory type for the kernel. Boot-services memory is free
/// once the firmware is gone; loader memory holds the kernel, its page tables
/// and this hand-off, so the kernel must keep it.
fn memType(t: uefi.tables.MemoryType) u64 {
    return switch (t) {
        .conventional_memory, .boot_services_code, .boot_services_data => bootinfo.MemmapEntry.USABLE,
        .loader_code, .loader_data => bootinfo.MemmapEntry.BOOTLOADER_RECLAIMABLE,
        else => bootinfo.MemmapEntry.RESERVED,
    };
}

const FbInfo: type = struct {
    fb: bootinfo.Framebuffer,
    phys: u64,
    masks: [4]u32,
};

/// Ask the firmware for its graphical output and describe it in BootInfo form.
fn queryFb() ?FbInfo {
    const gop = bs().locateProtocol(uefi.protocol.GraphicsOutput, null) catch return null;
    const g = gop orelse return null;
    const inf = g.mode.info;
    var masks: [4]u32 = .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 };
    switch (inf.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => {},
        .red_green_blue_reserved_8_bit_per_color => masks = .{ 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 },
        .bit_mask => {
            const pm = inf.pixel_information;
            masks = .{ pm.red_mask, pm.green_mask, pm.blue_mask, pm.reserved_mask };
        },
        else => return null, // blt-only: no linear framebuffer
    }
    const bits: u32 = @popCount(masks[0] | masks[1] | masks[2] | masks[3]);
    const bpp: u64 = if (bits > 24) 32 else if (bits > 16) 24 else 16;
    const phys: u64 = g.mode.frame_buffer_base;
    return .{
        .phys = phys,
        .masks = masks,
        .fb = .{
            .address = @ptrFromInt(phys + bootinfo.HHDM_OFFSET),
            .width = inf.horizontal_resolution,
            .height = inf.vertical_resolution,
            .pitch = @as(u64, inf.pixels_per_scan_line) * (bpp / 8),
            .bpp = @intCast(bpp),
            .memory_model = 1,
            .red_mask_size = @intCast(@popCount(masks[0])),
            .red_mask_shift = @intCast(@ctz(masks[0])),
            .green_mask_size = @intCast(@popCount(masks[1])),
            .green_mask_shift = @intCast(@ctz(masks[1])),
            .blue_mask_size = @intCast(@popCount(masks[2])),
            .blue_mask_shift = @intCast(@ctz(masks[2])),
        },
    };
}

/// The physical memory map, as the firmware reports it.
fn getMap() !uefi.tables.MemoryMapSlice {
    const info = try bs().getMemoryMapInfo();
    // The map can grow between queries, so leave a little room.
    const cap_bytes: usize = (info.len + 8) * info.descriptor_size;
    const pages: usize = (cap_bytes + 4095) / 4096 + 1;
    const mem = bs().allocatePages(.any, .loader_data, pages) catch return error.OutOfResources;
    const buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 =
        @alignCast(@as([*]u8, @ptrCast(mem.ptr))[0 .. pages * 4096]);
    return try bs().getMemoryMap(buf);
}
