// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// ELF64 image loader.
//
// This is the Zig counterpart of NetBSD's sys/kern/exec_elf.c (FreeBSD's
// sys/kern/imgact_elf.c): it maps an ELF image's loadable segments into the
// user address space and returns the entry point. Segments are written through
// their user virtual addresses because user and kernel share the page tables at
// this stage; a copyout path will replace this once the spaces are separated.

const elf: type = @import("../sys/exec_elf.zig");
const arch: type = @import("../arch/arch.zig");
const param: type = @import("../sys/param.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const prf: type = @import("subr_prf.zig");

/// What the loader reports back to the caller.
pub const Result: type = struct {
    /// Entry point virtual address.
    entry: u64,
};

/// True when `bytes` starts with the ELF magic.
pub fn isElf(bytes: []const u8) bool {
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
///
/// The bytes are written through the page's physical address (via the direct
/// map), not through its user virtual address: the segment is already mapped
/// with its final protection (read-only for text), so the kernel must not write
/// through that mapping.
fn loadSegment(pmap: arch.pmap.Pmap, bytes: []const u8, ph: *const elf.Phdr, hhdm: u64) bool {
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
    var i: u64 = 0;
    while (i < ph.p_filesz) : (i += 1) {
        const src: u64 = ph.p_offset + i;
        if (src >= bytes.len) {
            break;
        }
        const dst_pa: u64 = arch.pmap.extract(pmap, ph.p_vaddr + i) orelse return false;
        const dst: *u8 = @ptrFromInt(dst_pa + hhdm);
        dst.* = bytes[@intCast(src)];
    }
    return true;
}

/// Load an ELF64 executable image into page map `pmap`.
pub fn load(pmap: arch.pmap.Pmap, bytes: []const u8) ?Result {
    if (bytes.len < @sizeOf(elf.Ehdr) or !isElf(bytes)) {
        return null;
    }

    const ehdr: *const elf.Ehdr = @ptrFromInt(@intFromPtr(bytes.ptr));
    if (ehdr.e_type != elf.ET_EXEC or ehdr.e_machine != elf.EM_X86_64) {
        return null;
    }
    if (ehdr.e_phentsize != @sizeOf(elf.Phdr)) {
        return null;
    }

    const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;

    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const off: usize = @intCast(ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize);
        if (off + @sizeOf(elf.Phdr) > bytes.len) {
            return null;
        }
        const ph: *const elf.Phdr = @ptrFromInt(@intFromPtr(bytes.ptr) + off);
        if (ph.p_type == elf.PT_LOAD) {
            if (!loadSegment(pmap, bytes, ph, hhdm)) {
                prf.printLine("exec_elf: out of memory");
                return null;
            }
        }
    }

    return .{ .entry = ehdr.e_entry };
}
