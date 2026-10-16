// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Loading the kernel's ELF image.
//
// The counterpart of FreeBSD's stand/common/load_elf.c. The kernel is a
// static ELF64 executable whose loadable (PT_LOAD) segments are linked for a
// higher-half virtual address and a low physical address
// (kernel/arch/amd64/conf/kern.ldscript). The loader:
//
//   1. reads the whole file from the boot volume;
//   2. checks that it is an ELF64 executable for this machine;
//   3. measures the physical span its segments cover;
//   4. places that span in fresh loader memory, on a `md.KERNEL_ALIGN`
//      boundary so the page tables can map it with large pages;
//   5. copies each segment's file bytes and zeroes the rest of it (.bss),
//      printing each one the way FreeBSD's loader does:
//
//          /boot/kernel/kernel text=0x1f2a0 data=0x3c4f0+0x2b11c0
//
// The kernel is not relocated: it runs at the virtual addresses it was
// linked for, and the page tables built by the hand-off map that range onto
// wherever the span landed physically.

const std: type = @import("std");
const elf: type = std.elf;
const libefi: type = @import("libefi");
const md: type = @import("loader_md");
const platform: type = @import("platform");

/// Where a loaded kernel ended up, for the hand-off (handoff.zig).
pub const Kernel: type = struct {
    /// Virtual address of the first instruction (the ELF entry point).
    entry: u64,
    /// Physical address where the lowest segment was placed.
    phys_base: u64,
    /// Physical address the lowest segment was *linked* for (its p_paddr).
    link_phys_base: u64,
    /// Virtual address of the lowest segment (its p_vaddr).
    virt_base: u64,
    /// Bytes from the start of the lowest segment to the end of the highest.
    size: u64,
};

pub const Error: type = error{
    /// The file does not exist or cannot be read.
    NotFound,
    /// The file is not an ELF64 executable for this machine.
    NotElf,
    /// The file has no PT_LOAD segment, or one that lies outside the file.
    BadSegments,
    /// The firmware has no memory left for the kernel.
    OutOfMemory,
};

/// Load the kernel at `path` (as named by the user: `name`) into memory.
/// Prints why when it fails.
pub fn load(path: []const u8, name: []const u8) Error!Kernel {
    platform.print("Loading kernel...\n");
    const image: []u8 = platform.readFile(path) orelse {
        platform.printf("can't load '{s}'\n", .{name});
        return error.NotFound;
    };
    // The file is only needed until its segments are copied; give its pages
    // back so they become free memory for the kernel.
    defer platform.freeFile(image);

    const header: *const elf.Elf64.Ehdr = elfHeader(image) orelse {
        platform.printf("{s}: not an ELF file for this machine\n", .{path});
        return error.NotElf;
    };

    const extent: Extent = measure(image, header) orelse {
        platform.printf("{s}: no loadable segments\n", .{path});
        return error.BadSegments;
    };

    // Over-allocate by one alignment unit so an aligned start always fits.
    const region: libefi.Pages = libefi.allocatePages(libefi.pagesFor(extent.size + md.KERNEL_ALIGN)) orelse {
        platform.print("loader: not enough memory for the kernel\n");
        return error.OutOfMemory;
    };
    const phys_base: u64 = libefi.alignUp(libefi.physicalAddress(region.ptr), md.KERNEL_ALIGN);

    platform.print(path);
    for (0..header.phnum) |index| {
        const segment: *const elf.Elf64.Phdr = programHeader(image, header, index) orelse break;
        if (segment.type != .LOAD) continue;
        copySegment(image, segment, phys_base + (segment.paddr - extent.link_phys_base));
        report(segment);
    }
    platform.print("\n");

    return .{
        .entry = header.entry,
        .phys_base = phys_base,
        .link_phys_base = extent.link_phys_base,
        .virt_base = extent.virt_base,
        .size = extent.size,
    };
}

/// The ELF header of `image`, or null unless it is an ELF64 executable for
/// the machine this loader runs on.
fn elfHeader(image: []const u8) ?*const elf.Elf64.Ehdr {
    if (image.len < @sizeOf(elf.Elf64.Ehdr)) return null;
    // readFile returns page-aligned memory, so the header is aligned.
    const header: *const elf.Elf64.Ehdr = @ptrCast(@alignCast(image.ptr));
    if (!std.mem.eql(u8, &header.ident.magic, elf.MAGIC)) return null;
    if (header.ident.class != .@"64") return null;
    if (header.type != .EXEC) return null;
    if (header.machine != md.ELF_MACHINE) return null;
    if (header.phentsize != @sizeOf(elf.Elf64.Phdr)) return null;
    return header;
}

/// Program header `index` of `image`, or null when it lies outside the file.
fn programHeader(image: []const u8, header: *const elf.Elf64.Ehdr, index: usize) ?*const elf.Elf64.Phdr {
    const offset: u64 = header.phoff + @as(u64, index) * header.phentsize;
    if (offset + @sizeOf(elf.Elf64.Phdr) > image.len) return null;
    return @ptrCast(@alignCast(image.ptr + @as(usize, @intCast(offset))));
}

/// The range the PT_LOAD segments cover.
const Extent: type = struct {
    link_phys_base: u64,
    virt_base: u64,
    size: u64,
};

/// Measure the loadable segments of `image`. Returns null when there are
/// none, or when one claims bytes beyond the end of the file.
fn measure(image: []const u8, header: *const elf.Elf64.Ehdr) ?Extent {
    var phys_low: u64 = std.math.maxInt(u64);
    var phys_high: u64 = 0;
    var virt_low: u64 = std.math.maxInt(u64);
    for (0..header.phnum) |index| {
        const segment: *const elf.Elf64.Phdr = programHeader(image, header, index) orelse return null;
        if (segment.type != .LOAD) continue;
        if (segment.offset + segment.filesz > image.len or segment.filesz > segment.memsz) return null;
        phys_low = @min(phys_low, segment.paddr);
        phys_high = @max(phys_high, segment.paddr + segment.memsz);
        virt_low = @min(virt_low, segment.vaddr);
    }
    if (phys_low >= phys_high) return null;
    return .{ .link_phys_base = phys_low, .virt_base = virt_low, .size = phys_high - phys_low };
}

/// Copy `segment` from `image` to physical address `dest`, zero-filling the
/// part of it that is not in the file (.bss).
fn copySegment(image: []const u8, segment: *const elf.Elf64.Phdr, dest: u64) void {
    const target: [*]u8 = @ptrFromInt(@as(usize, @intCast(dest)));
    const file_size: usize = @intCast(segment.filesz);
    const memory_size: usize = @intCast(segment.memsz);
    const offset: usize = @intCast(segment.offset);
    @memcpy(target[0..file_size], image[offset..][0..file_size]);
    @memset(target[file_size..memory_size], 0);
}

/// Print one segment as FreeBSD's load_elf.c does: " text=0x<size>" for
/// code, " data=0x<file size>+0x<zero-filled size>" for data.
fn report(segment: *const elf.Elf64.Phdr) void {
    if (segment.flags.X) {
        platform.printf(" text=0x{x}", .{segment.filesz});
        return;
    }
    platform.printf(" data=0x{x}", .{segment.filesz});
    if (segment.memsz > segment.filesz) {
        platform.printf("+0x{x}", .{segment.memsz - segment.filesz});
    }
}
