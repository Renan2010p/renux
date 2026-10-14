// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// VirtIO definitions.
//
// The Zig counterpart of FreeBSD's sys/dev/virtio/virtio.h, virtio_config.h
// and virtio_ring.h: device status bits, device types and the split
// virtqueue layout shared by every transport (VirtIO 1.0, section 2.6).

/// Device status bits.
pub const VIRTIO_CONFIG_STATUS_RESET: u8 = 0x00;
pub const VIRTIO_CONFIG_STATUS_ACK: u8 = 0x01;
pub const VIRTIO_CONFIG_STATUS_DRIVER: u8 = 0x02;
pub const VIRTIO_CONFIG_STATUS_DRIVER_OK: u8 = 0x04;
pub const VIRTIO_CONFIG_STATUS_FEATURES_OK: u8 = 0x08;
pub const VIRTIO_CONFIG_STATUS_FAILED: u8 = 0x80;

/// Device types (the legacy PCI subsystem device id carries it).
pub const VIRTIO_ID_NETWORK: u16 = 1;
pub const VIRTIO_ID_BLOCK: u16 = 2;
pub const VIRTIO_ID_CONSOLE: u16 = 3;
pub const VIRTIO_ID_ENTROPY: u16 = 4;

/// Descriptor flags.
pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

/// Queues are laid out with this alignment by legacy devices.
pub const VIRTIO_PCI_VRING_ALIGN: u64 = 4096;

/// struct vring_desc.
pub const VringDesc: type = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// struct vring_used_elem.
pub const VringUsedElem: type = extern struct {
    id: u32,
    len: u32,
};

/// Bytes a split ring of `num` entries needs, with the used ring aligned
/// to `alignment` (vring_size()).
pub fn vring_size(num: u64, alignment: u64) u64 {
    const avail_end: u64 = 16 * num + 2 * (3 + num);
    const used_start: u64 = (avail_end + alignment - 1) / alignment * alignment;
    return used_start + 2 * 3 + 8 * num;
}

/// Offsets of the three parts of a split ring of `num` entries.
pub fn availOffset(num: u64) u64 {
    return 16 * num;
}

pub fn usedOffset(num: u64, alignment: u64) u64 {
    const avail_end: u64 = 16 * num + 2 * (3 + num);
    return (avail_end + alignment - 1) / alignment * alignment;
}
