// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Handing the machine to a loaded kernel.
//
// The counterpart of FreeBSD's stand/efi/loader/bootinfo.c and copy.c. Once
// load_elf.zig has placed the kernel in memory, `start` turns the loader's
// state into the Renux boot protocol (bootloader/arch/amd64/protocol) and
// jumps:
//
//   1. one page of loader memory receives the `Handoff`: the BootInfo, the
//      framebuffer description and the kernel command line;
//   2. the firmware's framebuffer is described (and reported on screen);
//   3. the machine-dependent code builds the kernel's page tables: an
//      identity map, the direct map at `bootinfo.HHDM_OFFSET`, and the kernel
//      at its link address;
//   4. the kernel's boot stack is allocated;
//   5. the BootInfo's address is written into the kernel's boot request;
//   6. the final memory map is taken, the firmware is left
//      (ExitBootServices) and the kernel is entered.
//
// The loader runs on the firmware's identity map, so it writes everything
// through physical addresses; the kernel will run on the new page tables, so
// every pointer it is given is a direct-map address of the same memory.

const std: type = @import("std");
const uefi: type = std.os.uefi;
const bootinfo: type = @import("bootinfo");
const libefi: type = @import("libefi");
const md: type = @import("loader_md");
const platform: type = @import("platform");
const env: type = @import("common").env;
const Kernel: type = @import("load_elf.zig").Kernel;

/// Size of the kernel's boot stack (64 KiB).
const KERNEL_STACK_PAGES: usize = 16;

/// Room for the memory map handed to the kernel (8 pages: 1365 entries).
const MEMMAP_PAGES: usize = 8;
const MEMMAP_CAPACITY: usize = MEMMAP_PAGES * libefi.PAGE_SIZE / @sizeOf(bootinfo.MemmapEntry);

/// ExitBootServices fails when the memory map changed since it was read, so
/// the loader reads it again and retries, at most this many times.
const EXIT_BOOT_SERVICES_ATTEMPTS: usize = 8;

/// Longest kernel command line, including its terminating NUL.
const CMDLINE_MAX: usize = 256;

/// Everything the kernel reads after the firmware is gone, kept together in
/// one page of loader memory (which the kernel never reuses).
const Handoff: type = extern struct {
    info: bootinfo.BootInfo,
    framebuffer: bootinfo.Framebuffer,
    cmdline: [CMDLINE_MAX]u8,
};

comptime {
    if (@sizeOf(Handoff) > libefi.PAGE_SIZE) @compileError("handoff: Handoff must fit in one page");
}

pub const Error: type = error{
    /// The firmware has no memory left for the hand-off.
    OutOfMemory,
    /// The kernel image carries no Renux boot request.
    NoBootRequest,
    /// The firmware refused to let go of the machine.
    ExitBootServicesFailed,
};

/// Start `kernel`. Returns only when that fails, after printing why.
pub fn start(kernel: Kernel) Error!noreturn {
    const handoff: *Handoff = @ptrCast(@alignCast((libefi.allocateZeroedPages(1) orelse return error.OutOfMemory).ptr));

    // The direct map must cover all RAM and the framebuffer.
    var direct_map_end: u64 = try physicalMemoryEnd();

    var framebuffer_count: u64 = 0;
    if (queryFramebuffer()) |fb| {
        handoff.framebuffer = fb.info;
        framebuffer_count = 1;
        direct_map_end = @max(direct_map_end, fb.phys_address + fb.size());
        fb.report();
    }
    direct_map_end = libefi.alignUp(direct_map_end, md.KERNEL_ALIGN);

    const cmdline_len: usize = writeCommandLine(handoff.cmdline[0 .. CMDLINE_MAX - 1]);
    handoff.cmdline[cmdline_len] = 0;

    const page_table_root: u64 = md.buildPageTables(.{
        .direct_map_end = direct_map_end,
        .direct_map_base = bootinfo.HHDM_OFFSET,
        .kernel_virt_base = kernel.virt_base,
        .kernel_phys_base = kernel.phys_base,
        .kernel_size = kernel.size,
    }) catch return error.OutOfMemory;

    // The boot stack is reached through the direct map: process address
    // spaces copy the kernel half of the page tables, not the identity map.
    const stack: libefi.Pages = libefi.allocatePages(KERNEL_STACK_PAGES) orelse return error.OutOfMemory;
    const stack_top: u64 = md.initialStackPointer(toDirectMap(stack.ptr) + KERNEL_STACK_PAGES * libefi.PAGE_SIZE);

    const memmap_pages: libefi.Pages = libefi.allocatePages(MEMMAP_PAGES) orelse return error.OutOfMemory;
    const memmap: [*]bootinfo.MemmapEntry = @ptrCast(@alignCast(memmap_pages.ptr));

    handoff.info = .{
        .magic = bootinfo.MAGIC,
        .revision = bootinfo.revision,
        .hhdm = bootinfo.HHDM_OFFSET,
        .memmap = @ptrFromInt(toDirectMap(memmap)),
        .memmap_count = 0, // filled in right before ExitBootServices
        .modules = null,
        .module_count = 0,
        .framebuffers = @ptrFromInt(toDirectMap(&handoff.framebuffer)),
        .framebuffer_count = framebuffer_count,
        .cmdline = @ptrFromInt(toDirectMap(&handoff.cmdline)),
        .physical_base = kernel.phys_base - kernel.link_phys_base,
        .virtual_base = kernel.virt_base,
    };

    const response: *u64 = findBootRequestResponse(kernel) orelse {
        platform.print("loader: the kernel has no Renux boot request\n");
        return error.NoBootRequest;
    };
    response.* = toDirectMap(&handoff.info);

    platform.printf("Start @ 0x{x} ...\n", .{kernel.entry});

    // Nothing may be printed from here on: printing can allocate, and any
    // allocation changes the memory map and invalidates its key.
    for (0..EXIT_BOOT_SERVICES_ATTEMPTS) |_| {
        const map: uefi.tables.MemoryMapSlice = memoryMap() catch break;
        handoff.info.memmap_count = translateMemoryMap(map, memmap[0..MEMMAP_CAPACITY]);
        libefi.bootServices().exitBootServices(uefi.handle, map.info.key) catch continue;
        md.enterKernel(kernel.entry, page_table_root, stack_top);
    }
    platform.print("loader: ExitBootServices failed\n");
    return error.ExitBootServicesFailed;
}

/// The direct-map address of loader memory at `ptr`.
fn toDirectMap(ptr: anytype) u64 {
    return libefi.physicalAddress(ptr) + bootinfo.HHDM_OFFSET;
}

// -- kernel command line -----------------------------------------------------

/// Write the kernel arguments for the loader's settings into `buf` and return
/// their length: FreeBSD's boot flags, the console list and the root device,
/// separated by single spaces, e.g.
///
///     -s -v console=vidconsole,comconsole vfs.root.mountfrom=ext2fs:/dev/vda2
///
/// An argument that does not fit is left out.
fn writeCommandLine(buf: []u8) usize {
    var line: ArgumentList = .{ .buf = buf };
    if (env.isYes("boot_single")) line.add("-s", "");
    if (env.isYes("boot_verbose")) line.add("-v", "");
    if (env.get("console")) |consoles| {
        // Spaces separate kernel arguments, so the list is joined with commas.
        const console_start: usize = line.len;
        line.add("console=", consoles);
        std.mem.replaceScalar(u8, buf[console_start..line.len], ' ', ',');
    }
    // An installed system names its ext2 root here; without it the kernel
    // mounts the root image it carries.
    if (env.get("vfs.root.mountfrom")) |root| line.add("vfs.root.mountfrom=", root);
    return line.len;
}

/// Space-separated arguments written into a fixed buffer.
const ArgumentList: type = struct {
    buf: []u8,
    len: usize = 0,

    /// Append the argument `key` ++ `value`, if it fits.
    fn add(list: *ArgumentList, key: []const u8, value: []const u8) void {
        const separator: usize = @intFromBool(list.len > 0);
        if (list.len + separator + key.len + value.len > list.buf.len) return;
        if (separator == 1) {
            list.buf[list.len] = ' ';
            list.len += 1;
        }
        @memcpy(list.buf[list.len..][0..key.len], key);
        list.len += key.len;
        @memcpy(list.buf[list.len..][0..value.len], value);
        list.len += value.len;
    }
};

// -- framebuffer -------------------------------------------------------------

/// The firmware's framebuffer, described for the kernel.
const FramebufferInfo: type = struct {
    info: bootinfo.Framebuffer,
    phys_address: u64,
    /// Red, green, blue and reserved channel masks, as UEFI reports them.
    masks: [4]u32,

    fn size(fb: FramebufferInfo) u64 {
        return fb.info.pitch * fb.info.height;
    }

    /// Print the framebuffer the way FreeBSD's loader does.
    fn report(fb: FramebufferInfo) void {
        platform.print("EFI framebuffer information:\n");
        platform.printf("addr, size     0x{x}, 0x{x}\n", .{ fb.phys_address, fb.size() });
        platform.printf("dimensions     {d} x {d}\n", .{ fb.info.width, fb.info.height });
        platform.printf("stride         {d}\n", .{fb.info.pitch / (fb.info.bpp / 8)});
        platform.printf("masks          0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}\n", .{ fb.masks[0], fb.masks[1], fb.masks[2], fb.masks[3] });
    }
};

/// Channel masks of the two fixed UEFI pixel formats.
const BGRX_MASKS: [4]u32 = .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 };
const RGBX_MASKS: [4]u32 = .{ 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 };

/// Ask the firmware for its graphics output and describe it in BootInfo
/// form. Returns null when there is none, or when it has no linear
/// framebuffer (a "blt only" display).
fn queryFramebuffer() ?FramebufferInfo {
    const gop: *uefi.protocol.GraphicsOutput = (libefi.bootServices().locateProtocol(uefi.protocol.GraphicsOutput, null) catch return null) orelse return null;
    const mode: *const uefi.protocol.GraphicsOutput.Mode.Info = gop.mode.info;
    const masks: [4]u32 = switch (mode.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => BGRX_MASKS,
        .red_green_blue_reserved_8_bit_per_color => RGBX_MASKS,
        .bit_mask => .{ mode.pixel_information.red_mask, mode.pixel_information.green_mask, mode.pixel_information.blue_mask, mode.pixel_information.reserved_mask },
        .blt_only => return null,
    };
    const used_bits: u32 = @popCount(masks[0] | masks[1] | masks[2] | masks[3]);
    const bpp: u16 = if (used_bits > 24) 32 else if (used_bits > 16) 24 else 16;
    const phys_address: u64 = gop.mode.frame_buffer_base;
    return .{
        .phys_address = phys_address,
        .masks = masks,
        .info = .{
            .address = @ptrFromInt(phys_address + bootinfo.HHDM_OFFSET),
            .width = mode.horizontal_resolution,
            .height = mode.vertical_resolution,
            .pitch = @as(u64, mode.pixels_per_scan_line) * (bpp / 8),
            .bpp = bpp,
            .memory_model = bootinfo.Framebuffer.MEMORY_MODEL_RGB,
            .red_mask_size = @intCast(@popCount(masks[0])),
            .red_mask_shift = @intCast(@ctz(masks[0])),
            .green_mask_size = @intCast(@popCount(masks[1])),
            .green_mask_shift = @intCast(@ctz(masks[1])),
            .blue_mask_size = @intCast(@popCount(masks[2])),
            .blue_mask_shift = @intCast(@ctz(masks[2])),
        },
    };
}

// -- memory map --------------------------------------------------------------

/// The physical memory map, as the firmware reports it now.
fn memoryMap() Error!uefi.tables.MemoryMapSlice {
    const bs: *uefi.tables.BootServices = libefi.bootServices();
    const info: uefi.tables.MemoryMapInfo = bs.getMemoryMapInfo() catch return error.OutOfMemory;
    // Allocating the buffer adds entries to the map, so leave room for them.
    const capacity: usize = (info.len + 8) * info.descriptor_size;
    const pages: libefi.Pages = libefi.allocatePages(libefi.pagesFor(capacity)) orelse return error.OutOfMemory;
    const buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @ptrCast(pages);
    return bs.getMemoryMap(buf) catch error.OutOfMemory;
}

/// The end of the highest range in the physical memory map.
fn physicalMemoryEnd() Error!u64 {
    const map: uefi.tables.MemoryMapSlice = try memoryMap();
    var end: u64 = 0;
    var it: uefi.tables.MemoryDescriptorIterator = map.iterator();
    while (it.next()) |d| end = @max(end, d.physical_start + d.number_of_pages * libefi.PAGE_SIZE);
    return end;
}

/// Copy the firmware's memory map into `out` in BootInfo form, and return the
/// number of entries written.
fn translateMemoryMap(map: uefi.tables.MemoryMapSlice, out: []bootinfo.MemmapEntry) u64 {
    var count: usize = 0;
    var it: uefi.tables.MemoryDescriptorIterator = map.iterator();
    while (it.next()) |d| {
        if (count == out.len) break;
        out[count] = .{
            .base = d.physical_start,
            .length = d.number_of_pages * libefi.PAGE_SIZE,
            .type = memoryType(d.type),
        };
        count += 1;
    }
    return count;
}

/// Translate a UEFI memory type for the kernel. Boot-services memory is free
/// once the firmware is gone; loader memory holds the kernel, its page tables
/// and this hand-off, so the kernel must keep it.
fn memoryType(t: uefi.tables.MemoryType) u64 {
    return switch (t) {
        .conventional_memory, .boot_services_code, .boot_services_data => bootinfo.MemmapEntry.USABLE,
        .loader_code, .loader_data => bootinfo.MemmapEntry.BOOTLOADER_RECLAIMABLE,
        else => bootinfo.MemmapEntry.RESERVED,
    };
}

// -- the boot request --------------------------------------------------------

/// The `response` field of the boot request inside the loaded kernel: the
/// first 8-byte-aligned occurrence of `bootinfo.requestId()` in its span.
fn findBootRequestResponse(kernel: Kernel) ?*u64 {
    const want: [4]u64 = bootinfo.requestId();
    const base: usize = @intCast(kernel.phys_base);
    var offset: usize = 0;
    while (offset + @sizeOf([4]u64) <= kernel.size) : (offset += @alignOf(bootinfo.Request)) {
        const candidate: *const [4]u64 = @ptrFromInt(base + offset);
        if (std.mem.eql(u64, candidate, &want)) {
            return @ptrFromInt(base + offset + bootinfo.Request.response_offset);
        }
    }
    return null;
}
