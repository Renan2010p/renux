// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The memory-mapping system calls: brk, mmap, munmap, mprotect, minherit,
// madvise.
//
// The Zig counterpart of FreeBSD's sys/vm/vm_mmap.c. Each call changes the
// process's address map (vm_map.zig); no page is made here. Pages appear on
// the first touch (vm_fault.zig), so a large reservation costs nothing until
// it is used, and munmap gives the memory back at once.

const std: type = @import("std");
const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const proc: type = @import("../sys/proc.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const kern_proc: type = @import("../core/kern_proc.zig");
const kern_descrip: type = @import("../core/kern_descrip.zig");
const prf: type = @import("../core/subr_prf.zig");
const file: type = @import("../sys/file.zig");
const vnode: type = @import("../sys/vnode.zig");
const vm_map: type = @import("vm_map.zig");

// mmap(2) flags (FreeBSD's sys/mman.h).
const MAP_SHARED: u64 = 0x0001;
const MAP_PRIVATE: u64 = 0x0002;
const MAP_FIXED: u64 = 0x0010;
const MAP_RESERVED0020: u64 = 0x0020; // ignored, as FreeBSD does
const MAP_RESERVED0040: u64 = 0x0040; // ignored, as FreeBSD does
const MAP_HASSEMAPHORE: u64 = 0x0200;
const MAP_STACK: u64 = 0x0400;
const MAP_NOSYNC: u64 = 0x0800;
const MAP_ANON: u64 = 0x1000;
const MAP_GUARD: u64 = 0x2000;
const MAP_EXCL: u64 = 0x4000;
const MAP_NOCORE: u64 = 0x20000;
const MAP_PREFAULT_READ: u64 = 0x40000;
const MAP_32BIT: u64 = 0x80000;
const MAP_ALIGNMENT_MASK: u64 = 0xff << 24;
/// The flags mmap(2) accepts.
const MAP_KNOWN: u64 = MAP_SHARED | MAP_PRIVATE | MAP_FIXED | MAP_HASSEMAPHORE | MAP_STACK | MAP_NOSYNC |
    MAP_ANON | MAP_EXCL | MAP_NOCORE | MAP_PREFAULT_READ | MAP_GUARD | MAP_32BIT | MAP_ALIGNMENT_MASK;
/// The flags MAP_GUARD may be combined with.
const MAP_GUARD_KNOWN: u64 = MAP_FIXED | MAP_GUARD | MAP_EXCL | MAP_32BIT | MAP_ALIGNMENT_MASK;

/// The protection bits, and PROT_MAX (the most a later mprotect(2) may
/// grant, in bits 16..18; accepted, and not enforced yet).
const PROT_ALL: u64 = vm_map.PROT_READ | vm_map.PROT_WRITE | vm_map.PROT_EXEC;
const PROT_MAX_SHIFT: u6 = 16;
/// MAP_ALIGNED(n) puts n in bits 24..31: align to 2^n bytes; n == 1 is
/// MAP_ALIGNED_SUPER, a superpage (2 MiB) boundary. FreeBSD's malloc
/// (jemalloc) relies on it to find a chunk's metadata by masking an address.
const MAP_ALIGNMENT_SHIFT: u6 = 24;
const MAP_ALIGNED_SUPER: u64 = 1;
const SUPERPAGE_SIZE: u64 = 2 * 1024 * 1024;

/// The lowest address mmap(2) hands out by itself, and the room below the
/// main stack it may use.
const MMAP_MIN: u64 = param.USER_MMAP_BASE;
fn mmapLimit() u64 {
    return arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
}
/// MAP_32BIT asks for an address below 2 GiB.
const LIMIT_32BIT: u64 = 0x8000_0000;

fn pageDown(a: u64) u64 {
    return a & ~@as(u64, param.PAGE_SIZE - 1);
}

fn pageUp(a: u64) u64 {
    return param.alignUp(a, param.PAGE_SIZE);
}

/// brk(2): `brk(addr)`, move the program break; 0 asks for it. The heap is
/// anonymous memory from the end of the program up to the break.
pub fn sysBrk(args: [sys.MAXARGS]u64) u64 {
    const addr: u64 = args[0];
    const p: *proc.Proc = kern_proc.current;
    if (addr == 0) return p.brk;

    const old_end: u64 = pageUp(p.brk);
    const new_end: u64 = pageUp(addr);
    if (new_end > old_end) {
        if (new_end > mmapLimit() or vm_map.overlaps(kern_proc.vmOf(p), old_end, new_end)) return sys.signed(-errno.ENOMEM);
        vm_map.insert(kern_proc.vmOf(p), p.pmap, .{
            .start = old_end,
            .end = new_end,
            .prot = vm_map.PROT_READ | vm_map.PROT_WRITE,
            .object = .anon,
        }) catch return sys.signed(-errno.ENOMEM);
    } else if (new_end < old_end) {
        vm_map.remove(kern_proc.vmOf(p), p.pmap, new_end, old_end) catch return sys.signed(-errno.ENOMEM);
    }
    p.brk = addr;
    return p.brk;
}

/// mmap(2): `mmap(addr, len, prot, flags, fd, pos)`. Map anonymous memory,
/// a file (privately: changes stay in the process) or a device's memory.
/// With MAP_FIXED the mapping goes exactly at `addr`, replacing what was
/// there (unless MAP_EXCL); otherwise `addr` is a hint and the first hole
/// that fits is used. The checks are FreeBSD's kern_mmap. Returns the
/// address.
pub fn sysMmap(args: [sys.MAXARGS]u64) u64 {
    const len: u64 = args[1];
    var flags: u64 = args[3] & ~(MAP_RESERVED0020 | MAP_RESERVED0040);
    // FreeBSD's mmap takes an `int` fd; the caller may pass -1 zero-extended.
    const fd: i64 = @as(i32, @bitCast(@as(u32, @truncate(args[4]))));
    var pos: u64 = args[5];
    const p: *proc.Proc = kern_proc.current;

    if ((args[2] & ~(PROT_ALL | (PROT_ALL << PROT_MAX_SHIFT))) != 0) return sys.signed(-errno.EINVAL);
    const prot: u8 = @truncate(args[2] & PROT_ALL);
    if (len == 0) return sys.signed(-errno.EINVAL);
    if ((flags & MAP_ANON) != 0 and (fd != -1 or pos != 0)) return sys.signed(-errno.EINVAL);
    if ((flags & MAP_STACK) != 0) {
        if (fd != -1 or (prot & (vm_map.PROT_READ | vm_map.PROT_WRITE)) != (vm_map.PROT_READ | vm_map.PROT_WRITE)) return sys.signed(-errno.EINVAL);
        flags |= MAP_ANON;
        pos = 0;
    }
    if ((flags & ~MAP_KNOWN) != 0) return sys.signed(-errno.EINVAL);
    if ((flags & (MAP_EXCL | MAP_FIXED)) == MAP_EXCL) return sys.signed(-errno.EINVAL);
    if ((flags & (MAP_SHARED | MAP_PRIVATE)) == (MAP_SHARED | MAP_PRIVATE)) return sys.signed(-errno.EINVAL);
    if ((flags & MAP_GUARD) != 0 and (prot != 0 or fd != -1 or pos != 0 or (flags & ~MAP_GUARD_KNOWN) != 0)) return sys.signed(-errno.EINVAL);

    // A file position need not be page-aligned: map from its page, and hand
    // back the address of the byte asked for.
    const pageoff: u64 = pos % param.PAGE_SIZE;
    pos -= pageoff;
    const size: u64 = pageUp(len + pageoff);
    if (size < len) return sys.signed(-errno.ENOMEM);
    const addr: u64 = args[0] -% pageoff;

    // Where the mapping goes.
    const align_req: u64 = (flags >> MAP_ALIGNMENT_SHIFT) & 0xff;
    const alignment: u64 = if (align_req == MAP_ALIGNED_SUPER)
        SUPERPAGE_SIZE
    else if (align_req >= param.PAGE_SHIFT and align_req < 48)
        @as(u64, 1) << @intCast(align_req)
    else
        param.PAGE_SIZE;
    var base: u64 = undefined;
    if ((flags & MAP_FIXED) != 0) {
        if (addr % param.PAGE_SIZE != 0) return sys.signed(-errno.EINVAL);
        if (addr + size > arch.vmparam.VM_MAXUSER_ADDRESS or addr + size < addr) return sys.signed(-errno.EINVAL);
        if ((flags & MAP_32BIT) != 0 and addr + size > LIMIT_32BIT) return sys.signed(-errno.EINVAL);
        if ((flags & MAP_EXCL) != 0 and vm_map.overlaps(kern_proc.vmOf(p), addr, addr + size)) return sys.signed(-errno.ENOMEM);
        base = addr;
    } else {
        const limit: u64 = if ((flags & MAP_32BIT) != 0) LIMIT_32BIT else mmapLimit();
        const hint: u64 = if (args[0] != 0) pageDown(addr) else @max(p.mmap_next, MMAP_MIN);
        base = vm_map.findSpace(kern_proc.vmOf(p), hint, size, alignment, limit) orelse
            vm_map.findSpace(kern_proc.vmOf(p), MMAP_MIN, size, alignment, limit) orelse
            return sys.signed(-errno.ENOMEM);
        if (args[0] == 0) p.mmap_next = base + size;
    }

    // What the pages are.
    const file_backed: bool = fd >= 0 and (flags & (MAP_ANON | MAP_GUARD)) == 0;
    if (!file_backed) {
        vm_map.insert(kern_proc.vmOf(p), p.pmap, .{ .start = base, .end = base + size, .prot = prot, .object = .anon }) catch
            return sys.signed(-errno.ENOMEM);
        return base;
    }
    const offset: u64 = pos;
    const f: *file.File = kern_descrip.fdGetfile(p, @intCast(fd)) orelse return sys.signed(-errno.EBADF);

    if (f.f_ops.mmap) |devmmap| {
        // A device with an mmap hook (/dev/fb0) maps its own memory now.
        vm_map.insert(kern_proc.vmOf(p), p.pmap, .{ .start = base, .end = base + size, .prot = prot, .object = .device }) catch
            return sys.signed(-errno.ENOMEM);
        const e: *vm_map.Entry = vm_map.lookup(kern_proc.vmOf(p), base).?;
        var page: u64 = 0;
        while (page < size) : (page += param.PAGE_SIZE) {
            const pa: u64 = devmmap(f, offset + page, @intCast(args[2])) orelse {
                vm_map.remove(kern_proc.vmOf(p), p.pmap, base, base + size) catch {};
                return sys.signed(-errno.ENXIO);
            };
            arch.pmap.enterDevice(p.pmap, base + page, pa, e.pmapProt());
        }
        return base + pageoff;
    }

    if (f.f_type != file.DTYPE_VNODE) return sys.signed(-errno.ENODEV);
    const vp: *vnode.Vnode = @ptrCast(@alignCast(f.f_data orelse return sys.signed(-errno.EBADF)));
    vm_map.insert(kern_proc.vmOf(p), p.pmap, .{
        .start = base,
        .end = base + size,
        .prot = prot,
        .object = .{ .vnode = .{
            .vp = vp,
            .offset = offset,
            .file_end = std.math.maxInt(u64),
            // A shared, writable mapping of a file opened for writing sends
            // its changes back to the file.
            .shared = (flags & MAP_SHARED) != 0 and (f.f_flag & file.FWRITE) != 0,
        } },
    }) catch return sys.signed(-errno.ENOMEM);
    prf.log(prf.LOG_DEBUG, "mmap: pid %d file at %x len %x", .{ p.pid, base, size });
    return base + pageoff;
}

/// A page-aligned range of user addresses, [start, end).
const UserRange: type = struct { start: u64, end: u64 };

/// The page-aligned range [addr, addr + len) of a call, or null when `addr`
/// is not page-aligned or the range wraps (EINVAL).
fn userRange(addr: u64, len: u64) ?UserRange {
    if (addr % param.PAGE_SIZE != 0) return null;
    const end: u64 = pageUp(addr + len);
    if (end < addr or end > arch.vmparam.VM_MAXUSER_ADDRESS) return null;
    return .{ .start = addr, .end = end };
}

/// munmap(2): `munmap(addr, len)`; remove the mappings in the range and
/// free their pages.
pub fn sysMunmap(args: [sys.MAXARGS]u64) u64 {
    if (args[1] == 0) return sys.signed(-errno.EINVAL);
    const r: UserRange = userRange(args[0], args[1]) orelse return sys.signed(-errno.EINVAL);
    const p: *proc.Proc = kern_proc.current;
    vm_map.remove(kern_proc.vmOf(p), p.pmap, r.start, r.end) catch return sys.signed(-errno.ENOMEM);
    return 0;
}

/// msync(2): `msync(addr, len, flags)`; write the changed pages of shared
/// file mappings in the range back to their files (FreeBSD's kern_msync).
/// The writes are done at once whatever the flags; MS_INVALIDATE has
/// nothing to drop, since mappings and files never hold different copies
/// that the file has newer.
pub fn sysMsync(args: [sys.MAXARGS]u64) u64 {
    const MS_ASYNC: u64 = 0x0001;
    const MS_INVALIDATE: u64 = 0x0002;
    const flags: u64 = args[2];
    if ((flags & (MS_ASYNC | MS_INVALIDATE)) == (MS_ASYNC | MS_INVALIDATE)) return sys.signed(-errno.EINVAL);
    const start: u64 = pageDown(args[0]);
    const end: u64 = pageUp(args[0] + args[1]);
    if (end < start) return sys.signed(-errno.EINVAL);
    const p: *proc.Proc = kern_proc.current;
    vm_map.sync(kern_proc.vmOf(p), p.pmap, start, end);
    return 0;
}

/// mprotect(2): `mprotect(addr, len, prot)`; change the protection of the
/// mappings in the range.
pub fn sysMprotect(args: [sys.MAXARGS]u64) u64 {
    const r: UserRange = userRange(args[0], args[1]) orelse return sys.signed(-errno.EINVAL);
    const prot: u8 = @truncate(args[2] & (vm_map.PROT_READ | vm_map.PROT_WRITE | vm_map.PROT_EXEC));
    const p: *proc.Proc = kern_proc.current;
    vm_map.protect(kern_proc.vmOf(p), p.pmap, r.start, r.end, prot) catch return sys.signed(-errno.ENOMEM);
    return 0;
}

/// minherit(2): `minherit(addr, len, inherit)`; how a fork child gets the
/// range: INHERIT_COPY a copy-on-write copy, INHERIT_ZERO fresh
/// zero-filled memory, INHERIT_NONE nothing. INHERIT_SHARE is treated as a
/// copy (memory shared across processes is not supported yet).
pub fn sysMinherit(args: [sys.MAXARGS]u64) u64 {
    const INHERIT_SHARE: u64 = 0;
    const INHERIT_COPY: u64 = 1;
    const INHERIT_NONE: u64 = 2;
    const INHERIT_ZERO: u64 = 3;
    const r: UserRange = userRange(args[0], args[1]) orelse return sys.signed(-errno.EINVAL);
    const inherit: vm_map.Inherit = switch (args[2]) {
        INHERIT_SHARE, INHERIT_COPY => .copy,
        INHERIT_NONE => .none,
        INHERIT_ZERO => .zero,
        else => return sys.signed(-errno.EINVAL),
    };
    const p: *proc.Proc = kern_proc.current;
    vm_map.setInherit(kern_proc.vmOf(p), r.start, r.end, inherit) catch return sys.signed(-errno.ENOMEM);
    return 0;
}

/// madvise(2): `madvise(addr, len, behavior)`. Advice only tells the kernel
/// how memory will be used; FreeBSD may ignore it, and so does Renux (even
/// MADV_DONTNEED and MADV_FREE leave the contents in place, which FreeBSD
/// also allows). The range is not checked further.
pub fn sysMadvise(args: [sys.MAXARGS]u64) u64 {
    const MADV_CORE: u64 = 9; // the highest advice value FreeBSD defines
    if (args[2] > MADV_CORE) return sys.signed(-errno.EINVAL);
    return 0;
}
