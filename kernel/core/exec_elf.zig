// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// ELF64 image loader.
//
// The Zig counterpart of FreeBSD's sys/kern/imgact_elf.c: it maps an ELF
// image's loadable segments into a process's address map (vm_map.zig) and
// returns the entry point. Nothing is copied up front: each PT_LOAD segment
// becomes entries of the map, and the pages come from the file when the
// program first touches them (vm_fault.zig), so a 150 MB executable costs
// only the pages it runs.
//
// A segment is mapped as FreeBSD's load_section does it:
//
//   - its file bytes, up to the last whole page of them, as a private
//     mapping of the file (copy-on-write: a write changes the process's
//     copy only);
//   - the rest -- the last, partial page of file bytes and the zero-filled
//     .bss after them -- as anonymous memory, with the partial page's file
//     bytes copied in.

const elf: type = @import("../sys/exec_elf.zig");
const arch: type = @import("../arch/arch.zig");
const param: type = @import("../sys/param.zig");
const vnode: type = @import("../sys/vnode.zig");
const prf: type = @import("subr_prf.zig");
const vm_map: type = @import("../vm/vm_map.zig");
const vm_fault: type = @import("../vm/vm_fault.zig");

/// The image being loaded: its file and size, and the address space it goes
/// into.
pub const Image: type = struct {
    vp: *vnode.Vnode,
    /// Size of the file in bytes.
    size: u64,
    map: *vm_map.VmMap,
    pmap: arch.pmap.Pmap,
};

/// What the loader reports back to the caller.
pub const Result: type = struct {
    /// Entry point virtual address.
    entry: u64,
    /// First free virtual address after the loaded segments (the initial
    /// program break).
    brk: u64,
    /// Virtual address of the program headers (for AT_PHDR).
    phdr: u64,
    /// Number and size of the program headers.
    phnum: u16,
    phentsize: u16,
    /// The PT_INTERP path, when the image has one (a dynamic executable).
    interp: [MAXINTERP]u8,
    interp_len: usize,
    /// PT_TLS: link-time address of the static TLS template, its file and
    /// memory sizes and its alignment (all zero when there is no PT_TLS).
    tls_vaddr: u64,
    tls_filesz: u64,
    tls_memsz: u64,
    tls_align: u64,
};

/// Longest interpreter path we accept from PT_INTERP.
pub const MAXINTERP: usize = 256;

/// Read exactly `buf.len` bytes of the image at `offset`; false on a short
/// read.
fn readFull(img: *const Image, offset: u64, buf: []u8) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const n: isize = img.vp.v_op.read(img.vp, offset + done, buf[done..]);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
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

/// The map protection of a segment with ELF flags `flags`.
fn protOf(flags: u32) u8 {
    var prot: u8 = 0;
    if ((flags & elf.PF_R) != 0) prot |= vm_map.PROT_READ;
    if ((flags & elf.PF_W) != 0) prot |= vm_map.PROT_WRITE;
    if ((flags & elf.PF_X) != 0) prot |= vm_map.PROT_EXEC;
    return prot;
}

fn pageDown(a: u64) u64 {
    return a & ~param.PAGE_MASK;
}

fn pageUp(a: u64) u64 {
    return param.alignUp(a, param.PAGE_SIZE);
}

/// Map one PT_LOAD segment: `filesz` bytes of the file at `offset` at
/// virtual address `vaddr`, followed by zeros up to `memsz` (FreeBSD's
/// load_section). Returns false when the segment is malformed or memory runs
/// out.
fn loadSection(img: *const Image, offset: u64, vaddr: u64, memsz: u64, filesz: u64, prot: u8) bool {
    // The file must hold the segment's bytes, and a segment cannot have
    // more file bytes than memory.
    if ((filesz != 0 and filesz + offset > img.size) or filesz > memsz) {
        prf.log(prf.LOG_ERR, "exec_elf: truncated ELF file", .{});
        return false;
    }
    // A file mapping needs the address and the offset to sit at the same
    // place in their pages (ELF requires it of PT_LOAD).
    if ((vaddr -% offset) % param.PAGE_SIZE != 0) {
        prf.log(prf.LOG_ERR, "exec_elf: segment address and offset are not page-congruent", .{});
        return false;
    }

    // The file bytes, up to their last whole page (all of them when there
    // is no .bss after them).
    const map_addr: u64 = pageDown(vaddr);
    const file_addr: u64 = pageDown(offset);
    const map_len: u64 = if (filesz == 0)
        0
    else if (memsz > filesz)
        pageDown(offset + filesz) - file_addr
    else
        pageUp(offset + filesz) - file_addr;
    if (map_len != 0) {
        vm_map.insert(img.map, img.pmap, .{
            .start = map_addr,
            .end = map_addr + map_len,
            .prot = prot,
            .object = .{ .vnode = .{ .vp = img.vp, .offset = file_addr, .file_end = offset + filesz } },
        }) catch return false;
        if (memsz == filesz) return true;
    }

    // The rest: anonymous memory from the page holding the last file bytes
    // to the end of the segment, writable for now so those bytes can be
    // copied in.
    const copy_len: u64 = if (filesz == 0) 0 else (offset + filesz) - pageDown(offset + filesz);
    const anon_addr: u64 = pageDown(vaddr + filesz);
    const anon_len: u64 = pageUp(vaddr + memsz) - anon_addr;
    if (anon_len != 0) {
        vm_map.insert(img.map, img.pmap, .{
            .start = anon_addr,
            .end = anon_addr + anon_len,
            .prot = prot | vm_map.PROT_WRITE,
            .object = .anon,
        }) catch return false;
    }
    // Copied in small pieces: this runs deep in execve on a 16 KiB kernel
    // stack.
    var copied: u64 = 0;
    while (copied < copy_len) {
        var chunk: [256]u8 = undefined;
        const n: usize = @intCast(@min(chunk.len, copy_len - copied));
        if (!readFull(img, pageDown(offset + filesz) + copied, chunk[0..n])) return false;
        if (!vm_fault.writeBytes(img.map, img.pmap, anon_addr + copied, chunk[0..n])) return false;
        copied += n;
    }
    // Take back the write access granted only for the copy.
    if ((prot & vm_map.PROT_WRITE) == 0 and anon_len != 0) {
        vm_map.protect(img.map, img.pmap, anon_addr, anon_addr + anon_len, prot) catch return false;
    }
    return true;
}

/// Load the ELF64 image `img` into its address space, placing its segments
/// at `base` plus their link-time addresses (`base` is zero for an ET_EXEC
/// image). Accepts ET_EXEC and ET_DYN (a PIE or the interpreter), and
/// reports a PT_INTERP interpreter when the image has one.
pub fn load(img: *const Image, base: u64) ?Result {
    var ehdr: elf.Ehdr = undefined;
    const ehdr_bytes: [*]u8 = @ptrCast(&ehdr);
    if (!readFull(img, 0, ehdr_bytes[0..@sizeOf(elf.Ehdr)])) {
        return null;
    }
    if (!isElfBytes(ehdr_bytes[0..@sizeOf(elf.Ehdr)])) {
        return null;
    }
    // Accept FreeBSD-branded images (e_ident[EI_OSABI] == ELFOSABI_FREEBSD), so
    // a binary built for FreeBSD loads here.
    if (ehdr.e_ident[7] == elf.ELFOSABI_FREEBSD) {
        prf.log(prf.LOG_DEBUG, "exec: FreeBSD-branded ELF", .{});
    }
    if (ehdr.e_type != elf.ET_EXEC and ehdr.e_type != elf.ET_DYN) {
        return null;
    }
    if (ehdr.e_machine != elf.EM_X86_64) {
        return null;
    }
    if (ehdr.e_phentsize != @sizeOf(elf.Phdr)) {
        return null;
    }

    var max_end: u64 = 0;
    var phdr: u64 = 0;
    var interp_buf: [MAXINTERP]u8 = undefined;
    var interp_len: usize = 0;
    var tls_vaddr: u64 = 0;
    var tls_filesz: u64 = 0;
    var tls_memsz: u64 = 0;
    var tls_align: u64 = 0;

    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var ph: elf.Phdr = undefined;
        const ph_bytes: [*]u8 = @ptrCast(&ph);
        const off: u64 = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        if (!readFull(img, off, ph_bytes[0..@sizeOf(elf.Phdr)])) {
            return null;
        }
        if (ph.p_type == elf.PT_LOAD) {
            const vend: u64 = base + param.alignUp(ph.p_vaddr + ph.p_memsz, param.PAGE_SIZE);
            if (vend > max_end) {
                max_end = vend;
            }
            // The program headers are inside this segment when e_phoff falls in
            // its file range.
            if (ph.p_offset <= ehdr.e_phoff and ehdr.e_phoff < ph.p_offset + ph.p_filesz) {
                phdr = base + ph.p_vaddr + (ehdr.e_phoff - ph.p_offset);
            }
            if (!loadSection(img, ph.p_offset, base + ph.p_vaddr, ph.p_memsz, ph.p_filesz, protOf(ph.p_flags))) {
                return null;
            }
        } else if (ph.p_type == elf.PT_INTERP) {
            const n: usize = if (ph.p_filesz > MAXINTERP) MAXINTERP else @intCast(ph.p_filesz);
            if (!readFull(img, ph.p_offset, interp_buf[0..n])) return null;
            var l: usize = n;
            while (l > 0 and interp_buf[l - 1] == 0) l -= 1;
            interp_len = l;
        } else if (ph.p_type == elf.PT_TLS) {
            tls_vaddr = base + ph.p_vaddr;
            tls_filesz = ph.p_filesz;
            tls_memsz = ph.p_memsz;
            tls_align = ph.p_align;
        }
    }

    return .{
        .entry = base + ehdr.e_entry,
        .brk = max_end,
        .phdr = phdr,
        .phnum = ehdr.e_phnum,
        .phentsize = ehdr.e_phentsize,
        .interp = interp_buf,
        .interp_len = interp_len,
        .tls_vaddr = tls_vaddr,
        .tls_filesz = tls_filesz,
        .tls_memsz = tls_memsz,
        .tls_align = tls_align,
    };
}
