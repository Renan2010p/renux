// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// ELF64 image loader.
//
// This is the Zig counterpart of NetBSD's sys/kern/exec_elf.c (FreeBSD's
// sys/kern/imgact_elf.c): it maps an ELF image's loadable segments into the
// user address space and returns the entry point. The image is read through a
// Source, so the same loader serves a boot module (a byte slice) and a file on
// a filesystem (a vnode); it never needs the whole image in memory at once.
//
// Segment bytes are written through their physical addresses (via the direct
// map), not through their user virtual addresses: a segment is mapped with its
// final protection (read-only for text), so the kernel must not write through
// that mapping.

const elf: type = @import("../sys/exec_elf.zig");
const arch: type = @import("../arch/arch.zig");
const param: type = @import("../sys/param.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const prf: type = @import("subr_prf.zig");

/// Where the loader reads an image from.
pub const Source: type = struct {
    /// Caller state passed back to `read` (e.g. a vnode).
    ctx: *anyopaque,
    /// Size of the image in bytes, for the loader's own bookkeeping.
    size: u64,
    /// Read up to `buf.len` bytes at `offset`, returning the count read; a
    /// short read (including zero at end of file) ends the request early.
    read: *const fn (ctx: *anyopaque, offset: u64, buf: []u8) usize,
};

/// What the loader reports back to the caller.
pub const Result: type = struct {
    /// Entry point virtual address.
    entry: u64,
};

/// Read exactly `buf.len` bytes, or fewer only at end of file.
fn readFull(src: Source, offset: u64, buf: []u8) usize {
    var done: usize = 0;
    while (done < buf.len) {
        const n: usize = src.read(src.ctx, offset + done, buf[done..]);
        if (n == 0) {
            break;
        }
        done += n;
    }
    return done;
}

/// True when `bytes` starts with the ELF magic.
fn isElfBytes(bytes: []const u8) bool {
    if (bytes.len < elf.ELFMAG.len) {
        return false;
    }
    return bytes[0] == elf.ELFMAG[0] and
        bytes[1] == elf.ELFMAG[1] and
        bytes[2] == elf.ELFMAG[2] and
        bytes[3] == elf.ELFMAG[3];
}

fn protFor(flags: u32) arch.pmap.Prot {
    if ((flags & elf.PF_X) != 0) {
        return .user_rx;
    }
    if ((flags & elf.PF_W) != 0) {
        return .user_rw;
    }
    return .user_ro;
}

/// Map one PT_LOAD segment and copy its file-backed bytes.
fn loadSegment(pmap: arch.pmap.Pmap, src: Source, ph: *const elf.Phdr, hhdm: u64) bool {
    const vstart: u64 = ph.p_vaddr & ~param.PAGE_MASK;
    const vend: u64 = param.alignUp(ph.p_vaddr + ph.p_memsz, param.PAGE_SIZE);
    const prot: arch.pmap.Prot = protFor(ph.p_flags);

    // Allocate and map every page the segment occupies (zero-filled).
    var va: u64 = vstart;
    while (va < vend) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return false;
        arch.pmap.enterUser(pmap, va, pa, prot);
    }

    // Copy the file-backed part over the zero-filled pages.
    var skip: u64 = 0;
    var buf: [512]u8 = undefined;
    while (skip < ph.p_filesz) {
        const want64: u64 = ph.p_filesz - skip;
        const want: usize = if (want64 > buf.len) buf.len else @intCast(want64);
        const got: usize = src.read(src.ctx, ph.p_offset + skip, buf[0..want]);
        if (got == 0) {
            break;
        }
        var k: usize = 0;
        while (k < got) : (k += 1) {
            const dst_pa: u64 = arch.pmap.extract(pmap, ph.p_vaddr + skip + k) orelse return false;
            const dst: *u8 = @ptrFromInt(dst_pa + hhdm);
            dst.* = buf[k];
        }
        skip += got;
    }
    return true;
}

/// Load an ELF64 executable image into page map `pmap`.
pub fn load(pmap: arch.pmap.Pmap, src: Source) ?Result {
    var ehdr: elf.Ehdr = undefined;
    const ehdr_bytes: [*]u8 = @ptrCast(&ehdr);
    if (readFull(src, 0, ehdr_bytes[0..@sizeOf(elf.Ehdr)]) != @sizeOf(elf.Ehdr)) {
        return null;
    }
    if (!isElfBytes(ehdr_bytes[0..@sizeOf(elf.Ehdr)])) {
        return null;
    }
    if (ehdr.e_type != elf.ET_EXEC or ehdr.e_machine != elf.EM_X86_64) {
        return null;
    }
    if (ehdr.e_phentsize != @sizeOf(elf.Phdr)) {
        return null;
    }

    const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;

    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var ph: elf.Phdr = undefined;
        const ph_bytes: [*]u8 = @ptrCast(&ph);
        const off: u64 = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        if (readFull(src, off, ph_bytes[0..@sizeOf(elf.Phdr)]) != @sizeOf(elf.Phdr)) {
            return null;
        }
        if (ph.p_type == elf.PT_LOAD) {
            if (!loadSegment(pmap, src, &ph, hhdm)) {
                prf.printLine("exec_elf: out of memory");
                return null;
            }
        }
    }

    return .{ .entry = ehdr.e_entry };
}
