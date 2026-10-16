// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Limine boot protocol bindings (kernel side).
//
// Hand port of the Limine Boot Protocol header
// (https://github.com/limine-bootloader/limine-protocol, 0BSD) to Zig,
// targeting protocol base revision 6.
//
// Renux boots with its own loader (bootloader/efi). These bindings are the
// fallback that lets the very same kernel also start under Limine: the
// kernel side of the Renux protocol (bootloader/arch/amd64/protocol/kernel.zig)
// answers from here whenever the Renux loader did not answer its request.
// limine.conf, next to this file, is the matching Limine configuration.
//
// Usage contract: the kernel leaves each request's `response` field NULL and
// the bootloader allocates the response and writes its address there. All
// accessors therefore go through `<request>.response`, never through storage
// owned by the kernel.
//
// The request objects are emitted into dedicated linker sections (see
// kernel/arch/amd64/conf/kern.ldscript) so that lld places them, in order,
// into the loaded image where Limine scans for them.

/// Protocol base revision this kernel requests.
pub const base_revision: u64 = 6;

// NOTE: the marker byte patterns below are written as inline literals, and
// never as named file-scope constants. Zig materialises referenced constants
// in .rodata; a stray duplicate of a start/end marker would confuse Limine's
// delimiter search (it uses the last start marker and the first end marker in
// the whole image). Inlining keeps exactly one copy of each marker.

/// The 32-byte identifier of a request: the protocol's common magic followed
/// by the two words that name the request.
fn requestId(comptime a: u64, comptime b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

/// A request object: the kernel fills `id` (and `revision`), Limine writes
/// the address of its answer into `response`.
fn Request(comptime Response: type) type {
    return extern struct {
        id: [4]u64,
        revision: u64 = 0,
        response: ?*Response = null,
    };
}

// -- Response layouts (must match the C protocol exactly) --------------------

pub const BootloaderInfoResponse: type = extern struct {
    revision: u64,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
};

pub const FirmwareTypeResponse: type = extern struct {
    revision: u64,
    firmware_type: u64,

    pub const X86_BIOS: u64 = 0;
    pub const EFI32: u64 = 1;
    pub const EFI64: u64 = 2;
    pub const SBI: u64 = 3;
};

pub const HhdmResponse: type = extern struct {
    revision: u64,
    offset: u64,
};

pub const ExecutableCmdlineResponse: type = extern struct {
    revision: u64,
    cmdline: ?[*:0]const u8,
};

pub const ExecutableAddressResponse: type = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const MemmapEntry: type = extern struct {
    base: u64,
    length: u64,
    type: u64,

    pub const USABLE: u64 = 0;
    pub const RESERVED: u64 = 1;
    pub const ACPI_RECLAIMABLE: u64 = 2;
    pub const ACPI_NVS: u64 = 3;
    pub const BAD_MEMORY: u64 = 4;
    pub const BOOTLOADER_RECLAIMABLE: u64 = 5;
    pub const EXECUTABLE_AND_MODULES: u64 = 6;
    pub const FRAMEBUFFER: u64 = 7;
    pub const RESERVED_MAPPED: u64 = 8;
};

pub const MemmapResponse: type = extern struct {
    revision: u64,
    entry_count: u64,
    entries: ?[*]?*MemmapEntry,
};

pub const Framebuffer: type = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    mode_count: u64,
    modes: ?[*]?*anyopaque,
};

pub const FramebufferResponse: type = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: ?[*]?*Framebuffer,
};

pub const Uuid: type = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

/// A file loaded by the bootloader (an executable, module or initrd entry).
pub const File: type = extern struct {
    revision: u64,
    address: ?*anyopaque,
    size: u64,
    path: ?[*:0]const u8,
    string: ?[*:0]const u8,
    media_type: u32,
    unused: u32,
    tftp_ipv4: [4]u8,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};

pub const ModuleResponse: type = extern struct {
    revision: u64,
    module_count: u64,
    modules: ?[*]?*File,
};

// -- Requests (exported into the loaded image) -------------------------------

export var requests_start: [4]u64 align(8) linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

export var base_revision_tag: [3]u64 align(8) linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, base_revision,
};

export var bootloader_info_request: Request(BootloaderInfoResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0xf55038d8e2a1202f, 0x279426fcf5f59740),
};

export var firmware_type_request: Request(FirmwareTypeResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x8c2f75d90bef28a8, 0x7045a4688eac00c3),
};

export var hhdm_request: Request(HhdmResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
};

export var cmdline_request: Request(ExecutableCmdlineResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x4b161536e598651e, 0xb390ad4a2f1f303a),
};

export var executable_address_request: Request(ExecutableAddressResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x71ba76863cc55f63, 0xb2644a48c516a487),
};

export var memmap_request: Request(MemmapResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
};

export var framebuffer_request: Request(FramebufferResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
};

export var module_request: Request(ModuleResponse) align(8) linksection(".limine_requests") = .{
    .id = requestId(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
};

export var requests_end: [2]u64 align(8) linksection(".limine_requests_end") = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

// -- Accessors ---------------------------------------------------------------

/// The bytes of a NUL-terminated string, without the terminator.
fn span(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

/// True when the bootloader recognised and supports our base revision. When it
/// does, it rewrites the third word of the base revision tag to 0.
pub fn baseRevisionSupported() bool {
    return base_revision_tag[2] == 0;
}

/// The name the bootloader reports, e.g. "Limine".
pub fn bootloaderName() ?[]const u8 {
    const response: *const BootloaderInfoResponse = bootloader_info_request.response orelse return null;
    const name: [*:0]const u8 = response.name orelse return null;
    return span(name);
}

/// The version string the bootloader reports.
pub fn bootloaderVersion() ?[]const u8 {
    const response: *const BootloaderInfoResponse = bootloader_info_request.response orelse return null;
    const version: [*:0]const u8 = response.version orelse return null;
    return span(version);
}

/// The firmware the bootloader ran on (`FirmwareTypeResponse.X86_BIOS`, ...).
pub fn firmwareType() ?u64 {
    const response: *const FirmwareTypeResponse = firmware_type_request.response orelse return null;
    return response.firmware_type;
}

/// The kernel command line from limine.conf.
pub fn cmdline() ?[]const u8 {
    const response: *const ExecutableCmdlineResponse = cmdline_request.response orelse return null;
    const c: [*:0]const u8 = response.cmdline orelse return null;
    return span(c);
}

/// The virtual address at which all of physical memory is mapped.
pub fn hhdmOffset() ?u64 {
    const response: *const HhdmResponse = hhdm_request.response orelse return null;
    return response.offset;
}

/// The virtual address the kernel was loaded at.
pub fn executableVirtualBase() ?u64 {
    const response: *const ExecutableAddressResponse = executable_address_request.response orelse return null;
    return response.virtual_base;
}

/// The number of entries in the physical memory map.
pub fn memmapEntryCount() ?usize {
    const response: *const MemmapResponse = memmap_request.response orelse return null;
    return @intCast(response.entry_count);
}

/// Entry `index` of the physical memory map.
pub fn memmapEntry(index: usize) ?*MemmapEntry {
    const response: *const MemmapResponse = memmap_request.response orelse return null;
    if (index >= response.entry_count) return null;
    const entries: [*]?*MemmapEntry = response.entries orelse return null;
    return entries[index];
}

/// The number of framebuffers.
pub fn framebufferCount() ?usize {
    const response: *const FramebufferResponse = framebuffer_request.response orelse return null;
    return @intCast(response.framebuffer_count);
}

/// Framebuffer `index`.
pub fn framebuffer(index: usize) ?*Framebuffer {
    const response: *const FramebufferResponse = framebuffer_request.response orelse return null;
    if (index >= response.framebuffer_count) return null;
    const framebuffers: [*]?*Framebuffer = response.framebuffers orelse return null;
    return framebuffers[index];
}

/// The number of modules loaded with the kernel.
pub fn moduleCount() ?usize {
    const response: *const ModuleResponse = module_request.response orelse return null;
    return @intCast(response.module_count);
}

/// Module `index`.
pub fn module(index: usize) ?*File {
    const response: *const ModuleResponse = module_request.response orelse return null;
    if (index >= response.module_count) return null;
    const modules: [*]?*File = response.modules orelse return null;
    return modules[index];
}
