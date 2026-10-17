// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Page faults.
//
// The Zig counterpart of FreeBSD's sys/vm/vm_fault.c. A page fault on a user
// address is resolved from the process's map (vm_map.zig):
//
//   - a page the map allows but the page tables lack is made: zero-filled
//     for anonymous memory, read from the file for a file mapping (the
//     program, its libraries, mmap of a file);
//   - a write to a page shared copy-on-write since a fork gets the
//     process its own copy (pmap.resolveCow);
//   - anything else (no entry, or an access the protection forbids) is not
//     resolved, and the caller sends SIGSEGV.
//
// Programs reserve far more than they touch (malloc arenas, thread stacks,
// a 150 MB compiler binary), so only the pages actually used take memory.

const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const vm_page: type = @import("vm_page.zig");
const vm_map: type = @import("vm_map.zig");
const vnode: type = @import("../sys/vnode.zig");

/// Resolve a fault at `va` in the address space (`map`, `pmap`): a read, or
/// a write when `write` is set. Returns false when the access is not
/// allowed.
pub fn fault(map: *vm_map.VmMap, pmap: arch.pmap.Pmap, va: u64, write: bool) bool {
    const e: *vm_map.Entry = vm_map.lookup(map, va) orelse return false;
    if (e.prot == 0) return false;
    if (write and (e.prot & vm_map.PROT_WRITE) == 0) return false;
    const page_va: u64 = va & ~@as(u64, param.PAGE_SIZE - 1);

    if (arch.pmap.extract(pmap, page_va) != null) {
        // The page is there: a write to a copy-on-write page, or a fault
        // another thread already resolved.
        if (write) return arch.pmap.resolveCow(pmap, page_va);
        return true;
    }

    const pa: vm_page.PAddr = switch (e.object) {
        .anon => vm_page.allocUser() orelse return false,
        .vnode => |v| fromFile(v.vp, v.offset + (page_va - e.start), v.file_end) orelse return false,
        // Device pages are mapped with the entry; a hole is no page at all.
        .device => return false,
    };
    arch.pmap.enterUser(pmap, page_va, pa.int(), e.pmapProt());
    return true;
}

/// A new page holding the file bytes at `offset`, up to `file_end`; the
/// rest of the page is zero.
fn fromFile(vp: *vnode.Vnode, offset: u64, file_end: u64) ?vm_page.PAddr {
    const pa: vm_page.PAddr = vm_page.allocUser() orelse return null;
    if (offset < file_end) {
        const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;
        const dst: [*]u8 = @ptrFromInt(pa.int() + hhdm);
        const n: usize = @intCast(@min(param.PAGE_SIZE, file_end - offset));
        if (vp.v_op.read(vp, offset, dst[0..n]) < 0) {
            vm_page.unref(pa);
            return null;
        }
    }
    return pa;
}

/// The physical address of `va` in (`map`, `pmap`), faulting the page in
/// (for writing when `write` is set). For the kernel's own accesses to an
/// address space that is not the current one, such as a new program's
/// stack while execve(2) builds it.
pub fn hold(map: *vm_map.VmMap, pmap: arch.pmap.Pmap, va: u64, write: bool) ?u64 {
    if (!fault(map, pmap, va, write)) return null;
    return arch.pmap.extract(pmap, va);
}

/// Copy `bytes` to `va` in (`map`, `pmap`), a page at a time, faulting the
/// pages in. Returns false when part of the range is not writable.
pub fn writeBytes(map: *vm_map.VmMap, pmap: arch.pmap.Pmap, va: u64, bytes: []const u8) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    var done: usize = 0;
    while (done < bytes.len) {
        const addr: u64 = va + done;
        const n: usize = @min(@as(usize, @intCast(param.PAGE_SIZE - addr % param.PAGE_SIZE)), bytes.len - done);
        const pa: u64 = hold(map, pmap, addr, true) orelse return false;
        const dst: [*]u8 = @ptrFromInt(pa + hhdm);
        @memcpy(dst[0..n], bytes[done..][0..n]);
        done += n;
    }
    return true;
}

/// Copy `out.len` bytes from `va` in (`map`, `pmap`), faulting the pages
/// in. Returns false when part of the range is not readable.
pub fn readBytes(map: *vm_map.VmMap, pmap: arch.pmap.Pmap, va: u64, out: []u8) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    var done: usize = 0;
    while (done < out.len) {
        const addr: u64 = va + done;
        const n: usize = @min(@as(usize, @intCast(param.PAGE_SIZE - addr % param.PAGE_SIZE)), out.len - done);
        const pa: u64 = hold(map, pmap, addr, false) orelse return false;
        const src: [*]const u8 = @ptrFromInt(pa + hhdm);
        @memcpy(out[done..][0..n], src[0..n]);
        done += n;
    }
    return true;
}
