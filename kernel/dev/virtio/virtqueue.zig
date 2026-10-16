// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Virtqueues.
//
// The Zig counterpart of FreeBSD's sys/dev/virtio/virtqueue.c, reduced to the
// synchronous use a block device makes of it: the driver posts one chain of
// buffers, notifies the device and waits for the chain to come back on the
// used ring. The ring lives in physically contiguous pages reached through
// the direct map; the transport tells the device where it is.

const arch: type = @import("../../arch/arch.zig");
const param: type = @import("../../sys/param.zig");
const vm_page: type = @import("../../vm/vm_page.zig");
const virtio: type = @import("virtio.zig");

/// One buffer of a request: physical address, length, and whether the
/// device writes it (as opposed to reading it).
pub const Segment: type = struct {
    paddr: u64,
    len: u32,
    device_writes: bool,
};

pub const Virtqueue: type = struct {
    index: u16,
    num: u16,
    /// Physical address of the ring (what the transport hands the device).
    paddr: u64,
    desc: [*]volatile virtio.VringDesc,
    avail_flags: *volatile u16,
    avail_idx: *volatile u16,
    avail_ring: [*]volatile u16,
    used_flags: *volatile u16,
    used_idx: *volatile u16,
    used_ring: [*]volatile virtio.VringUsedElem,
    /// The used index the driver has consumed up to.
    used_last: u16,
    /// Tell the device the queue has new buffers.
    notify: *const fn (ctx: ?*anyopaque, index: u16) void,
    notify_ctx: ?*anyopaque,
};

/// Set up queue `index` with `num` entries in fresh zeroed memory. Returns
/// false when memory runs out.
pub fn alloc(vq: *Virtqueue, index: u16, num: u16, notify: *const fn (?*anyopaque, u16) void, ctx: ?*anyopaque) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    const size: u64 = virtio.vring_size(num, virtio.VIRTIO_PCI_VRING_ALIGN);
    const pages: u64 = (size + param.PAGE_SIZE - 1) / param.PAGE_SIZE;
    const pa: u64 = (vm_page.physallocContig(pages) orelse return false).int();
    const va: u64 = pa + hhdm;
    @memset(@as([*]u8, @ptrFromInt(va))[0..@intCast(pages * param.PAGE_SIZE)], 0);

    const avail: u64 = va + virtio.availOffset(num);
    const used: u64 = va + virtio.usedOffset(num, virtio.VIRTIO_PCI_VRING_ALIGN);
    vq.* = .{
        .index = index,
        .num = num,
        .paddr = pa,
        .desc = @ptrFromInt(va),
        .avail_flags = @ptrFromInt(avail),
        .avail_idx = @ptrFromInt(avail + 2),
        .avail_ring = @ptrFromInt(avail + 4),
        .used_flags = @ptrFromInt(used),
        .used_idx = @ptrFromInt(used + 2),
        .used_ring = @ptrFromInt(used + 4),
        .used_last = 0,
        .notify = notify,
        .notify_ctx = ctx,
    };
    // The driver polls the used ring: ask the device not to interrupt.
    vq.avail_flags.* = 1; // VRING_AVAIL_F_NO_INTERRUPT
    return true;
}

/// Post `segs` as one chain, notify the device and wait until it has
/// processed the chain. Returns false when the device does not answer.
pub fn enqueueWait(vq: *Virtqueue, segs: []const Segment) bool {
    if (segs.len == 0 or segs.len > vq.num) return false;
    // One request at a time: the chain always starts at descriptor 0.
    for (segs, 0..) |s, i| {
        var flags: u16 = 0;
        if (s.device_writes) flags |= virtio.VRING_DESC_F_WRITE;
        if (i + 1 < segs.len) flags |= virtio.VRING_DESC_F_NEXT;
        vq.desc[i] = .{ .addr = s.paddr, .len = s.len, .flags = flags, .next = @intCast(i + 1) };
    }
    const slot: u16 = vq.avail_idx.* % vq.num;
    vq.avail_ring[slot] = 0;
    // The descriptors and the ring entry must be visible before the index.
    arch.cpu.mb();
    vq.avail_idx.* = vq.avail_idx.* +% 1;
    arch.cpu.mb();
    vq.notify(vq.notify_ctx, vq.index);

    var spins: u64 = 0;
    while (vq.used_idx.* == vq.used_last) : (spins += 1) {
        if (spins > 2_000_000_000) return false;
        arch.cpu.cpu_spinwait();
    }
    arch.cpu.mb();
    vq.used_last +%= 1;
    return true;
}
