// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux boot protocol: the data the loader and the kernel agree on.
//
// This one file is compiled into both programs, so the layout of every
// structure below cannot drift between them:
//
//   - the UEFI loader (bootloader/efi/handoff.zig) fills a `BootInfo`;
//   - the kernel (bootloader/arch/amd64/protocol/kernel.zig) reads it.
//
// How the BootInfo reaches the kernel
// -----------------------------------
// The kernel image carries one `Request` object in its `.renux_requests`
// section. Its first 32 bytes are the `request_id` below, a value that occurs
// nowhere else in the image. After loading the kernel the loader scans the
// loaded segments for those 32 bytes, and writes the (direct-map) address of
// the BootInfo into the request's `response` field. The kernel then follows
// that pointer. A null `response` therefore means "not started by the Renux
// loader".
//
// Every pointer in a BootInfo is a direct-map (HHDM) virtual address: the
// kernel runs on the page tables the loader built, where physical memory is
// mapped at `HHDM_OFFSET`.
//
// This is the Zig counterpart of FreeBSD's sys/sys/bootinfo.h.

/// Marks a valid BootInfo: the ASCII bytes "RenuxBoo" read as a big-endian
/// 64-bit number.
pub const MAGIC: u64 = 0x5265_6e75_7842_6f6f;

/// Protocol revision. Bump it whenever a structure below changes.
pub const revision: u64 = 1;

/// Where the loader maps all of physical memory in the kernel's address space
/// (the higher-half direct map, HHDM): PML4 slot 273, as in the higher-half
/// layouts of Linux and FreeBSD.
pub const HHDM_OFFSET: u64 = 0xffff_8880_0000_0000;

/// One range of the physical memory map.
pub const MemmapEntry: type = extern struct {
    /// Physical address of the first byte.
    base: u64,
    /// Length of the range in bytes.
    length: u64,
    /// What the range holds: one of the constants below.
    type: u64,

    /// Free RAM the kernel may use.
    pub const USABLE: u64 = 0;
    /// Not RAM, or RAM the firmware keeps (ACPI, MMIO, runtime services).
    pub const RESERVED: u64 = 1;
    /// RAM the loader used: the kernel image, its page tables and this
    /// hand-off. The kernel must keep it while it uses the BootInfo.
    pub const BOOTLOADER_RECLAIMABLE: u64 = 2;
    /// RAM holding the kernel and the files loaded with it.
    pub const EXECUTABLE_AND_MODULES: u64 = 3;
    /// The framebuffer.
    pub const FRAMEBUFFER: u64 = 4;
};

/// A linear framebuffer the loader found (the UEFI Graphics Output Protocol).
pub const Framebuffer: type = extern struct {
    /// Direct-map virtual address of the first pixel.
    address: ?*anyopaque,
    /// Visible width in pixels.
    width: u64,
    /// Visible height in pixels.
    height: u64,
    /// Bytes from the start of one scanline to the start of the next.
    pitch: u64,
    /// Bits per pixel (16, 24 or 32).
    bpp: u16,
    /// Pixel memory model; 1 means "RGB", the only one the loader reports.
    memory_model: u8,
    /// Width and position of each colour channel inside a pixel.
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,

    /// The only value of `memory_model` in use.
    pub const MEMORY_MODEL_RGB: u8 = 1;
};

/// A file the loader loaded besides the kernel (a module). The layout is the
/// one Limine uses, so the kernel reads both protocols the same way.
pub const File: type = extern struct {
    revision: u64,
    /// Direct-map virtual address of the file's contents.
    address: ?*anyopaque,
    /// Size of the file in bytes.
    size: u64,
    /// Path the file was loaded from.
    path: ?[*:0]const u8,
    /// Free-form string attached to the file.
    string: ?[*:0]const u8,
    media_type: u32,
    unused: u32,
};

/// Everything the loader tells the kernel.
pub const BootInfo: type = extern struct {
    /// Always `MAGIC`.
    magic: u64,
    /// Always `revision`.
    revision: u64,
    /// Virtual address where physical address 0 is mapped (`HHDM_OFFSET`).
    hhdm: u64,
    /// The physical memory map, as it was when the firmware was left.
    memmap: ?[*]MemmapEntry,
    memmap_count: u64,
    /// Files loaded with the kernel (none yet: the root image is embedded).
    modules: ?[*]File,
    module_count: u64,
    /// The framebuffers (zero or one).
    framebuffers: ?[*]Framebuffer,
    framebuffer_count: u64,
    /// The kernel command line ("-s -v console=... vfs.root.mountfrom=...").
    cmdline: ?[*:0]const u8,
    /// Physical address the kernel's lowest segment was loaded at, minus the
    /// physical address it was linked for.
    physical_base: u64,
    /// Virtual address of the kernel's lowest segment.
    virtual_base: u64,
};

/// The 32 bytes that identify the request object in the kernel image: the
/// ASCII text "RenuxBOOProtocol" followed by two words holding 1.
///
/// This is a function, not a named constant, on purpose: the loader patches
/// the *first* copy of these bytes it finds in the kernel, so the kernel must
/// hold exactly one, the request itself. A constant the kernel referenced at
/// run time could be materialised as a second copy in .rodata; a value
/// returned by a function and used in a comptime initializer never is.
pub fn requestId() [4]u64 {
    return .{
        0x52656e7578424f4f, // "RenuxBOO"
        0x50726f746f636f6c, // "Protocol"
        0x0000000000000001,
        0x0000000000000001,
    };
}

/// The request object the kernel embeds and the loader answers.
pub const Request: type = extern struct {
    /// Always `requestId()`.
    id: [4]u64,
    /// The protocol revision the kernel was built for.
    revision: u64,
    /// Written by the loader: the BootInfo's direct-map address.
    response: ?*BootInfo,

    /// Byte offset of `response`, where the loader writes the answer.
    pub const response_offset: usize = @offsetOf(Request, "response");
};

comptime {
    // The loader and the kernel are compiled separately; pin the layout that
    // both depend on so a change here cannot silently break one of them.
    if (Request.response_offset != 40) @compileError("bootinfo: Request.response must stay at offset 40");
}
