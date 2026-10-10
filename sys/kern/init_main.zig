// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-independent kernel entry point.
//
// main() is called from the MD entry code (arch/amd64/amd64/locore.zig). It
// must remain machine independent: it brings up the console through the arch
// dispatch, reports the boot environment through the arch-provided boot
// protocol bindings, and then hands control to the machine-dependent idle
// loop. It never names a driver or a boot protocol directly.

const arch: type = @import("../arch/arch.zig");
const rasops: type = @import("../dev/rasops/rasops.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const prf: type = @import("subr_prf.zig");

/// Build a machine-independent raster description from the boot framebuffer.
fn buildRaster() ?rasops.Raster {
    const fb = arch.boot.framebuffer(0) orelse return null;
    const address = fb.address orelse return null;
    return .{
        .base = @ptrCast(address),
        .width = @intCast(fb.width),
        .height = @intCast(fb.height),
        .stride = @intCast(fb.pitch),
        .depth = @intCast(fb.bpp),
        .red_mask_size = fb.red_mask_size,
        .red_mask_shift = fb.red_mask_shift,
        .green_mask_size = fb.green_mask_size,
        .green_mask_shift = fb.green_mask_shift,
        .blue_mask_size = fb.blue_mask_size,
        .blue_mask_shift = fb.blue_mask_shift,
    };
}

/// Bring up the physical page allocator and the machine page map, then run a
/// mapping self-test.
fn bringUpVm(hhdm: u64) void {
    arch.pmap.bootstrap(hhdm);
    uvm_page.init(hhdm);

    const entries: usize = arch.boot.memmapEntryCount() orelse 0;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        const entry = arch.boot.memmapEntry(i) orelse continue;
        if (entry.type == arch.boot.MemmapEntry.USABLE) {
            uvm_page.physload(entry.base, entry.base + entry.length);
        }
    }

    prf.print("  phys memory:   ");
    prf.printDec(uvm_page.freeCount());
    prf.printLine(" free pages");

    // Allocate a page, map it at a scratch kernel address, and read it back.
    const va: u64 = arch.vmparam.KERNEL_SCRATCH_BASE;
    const pa: u64 = uvm_page.physalloc() orelse {
        prf.printLine("  vm: out of physical memory");
        return;
    };
    arch.pmap.kenterPa(va, pa, .kernel_rw);

    const cell: *volatile u64 = @ptrFromInt(va);
    cell.* = 0x5a5a_5a5a_5a5a_5a5a;
    const readback: u64 = cell.*;
    const translated: u64 = arch.pmap.extract(va) orelse 0;

    prf.print("  vm: pa ");
    prf.printHex(pa);
    prf.print(" at va ");
    prf.printHex(va);
    prf.print(" extract ");
    prf.printHex(translated);
    prf.print(" read ");
    prf.printHex(readback);
    prf.printLine("");
}

pub export fn main() void {
    arch.consinit.consinit(buildRaster());

    prf.printLine("");
    prf.printLine("ZenBSD: kernel entered");

    prf.print("  base revision: ");
    prf.printLine(if (arch.boot.baseRevisionSupported()) "ok" else "unsupported");

    prf.print("  bootloader:    ");
    if (arch.boot.bootloaderName()) |name| {
        prf.print(name);
        if (arch.boot.bootloaderVersion()) |version| {
            prf.print(" ");
            prf.print(version);
        }
    } else {
        prf.print("unknown");
    }
    prf.printLine("");

    prf.print("  firmware:      ");
    switch (arch.boot.firmwareType() orelse 0xff) {
        arch.boot.FirmwareTypeResponse.X86_BIOS => prf.printLine("x86 BIOS"),
        arch.boot.FirmwareTypeResponse.EFI32 => prf.printLine("EFI32"),
        arch.boot.FirmwareTypeResponse.EFI64 => prf.printLine("EFI64"),
        arch.boot.FirmwareTypeResponse.SBI => prf.printLine("SBI"),
        else => prf.printLine("unknown"),
    }

    if (arch.boot.hhdmOffset()) |offset| {
        prf.print("  hhdm:          ");
        prf.printHex(offset);
        prf.printLine("");
    }

    if (arch.boot.executableVirtualBase()) |vbase| {
        prf.print("  load base:     ");
        prf.printHex(vbase);
        prf.printLine("");
    }

    if (arch.boot.memmapEntryCount()) |count| {
        prf.print("  memmap:        ");
        prf.printDec(count);
        prf.printLine(" entries");
    }

    if (arch.boot.framebuffer(0)) |fb| {
        prf.print("  framebuffer:   ");
        prf.printDec(fb.width);
        prf.print("x");
        prf.printDec(fb.height);
        prf.print("x");
        prf.printDec(fb.bpp);
        prf.printLine("");
    }

    if (arch.boot.cmdline()) |line| {
        if (line.len != 0) {
            prf.print("  cmdline:       ");
            prf.printLine(line);
        }
    }

    if (arch.boot.hhdmOffset()) |hhdm| {
        bringUpVm(hhdm);
    }

    prf.printLine("");
    prf.printLine("ZenBSD: IDT self-test (int3):");
    arch.cpu.breakpoint();
    prf.printLine("ZenBSD: trap handler returned.");

    prf.printLine("");
    prf.printLine("ZenBSD: entering idle.");
    arch.cpu.idle();
}
