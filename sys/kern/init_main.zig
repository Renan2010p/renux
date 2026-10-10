// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Kernel main: system startup.
//
// This mirrors the startup sequence of NetBSD's sys/kern/init_main.c: find the
// console, announce the system, initialise the virtual memory system, configure
// the hardware (which enables interrupts) and hand off to init(8). The long
// middle of NetBSD's main() -- process 0, the scheduler, filesystems,
// networking and so on -- is not implemented yet and is noted where it belongs.

const arch: type = @import("../arch/arch.zig");
const rasops: type = @import("../dev/rasops/rasops.zig");
const uvm_init: type = @import("../uvm/uvm_init.zig");
const uvm_fault: type = @import("../uvm/uvm_fault.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Kernel version string, as NetBSD's version.h provides.
const version: []const u8 = "ZenBSD 0.1 (amd64)";

/// Build a machine-independent raster from the boot framebuffer.
fn bootRaster() ?rasops.Raster {
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

/// Print the system start-up banner (cf. NetBSD's banner()).
fn banner() void {
    prf.printLine(version);

    prf.print("  bootloader:    ");
    if (arch.boot.bootloaderName()) |name| {
        prf.print(name);
        if (arch.boot.bootloaderVersion()) |v| {
            prf.print(" ");
            prf.print(v);
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
}

/// Attempt to find the console and initialize it, for early panic messages.
/// (NetBSD's consinit(), implemented machine-dependently.)
fn consinit() void {
    arch.consinit.consinit(bootRaster());
}

/// Configure the system hardware. This brings up interrupts (NetBSD's
/// configure(), whose cpu_configure() enables them).
fn configure() void {
    arch.intr.init();
    arch.clock.init();

    prf.printLine("");
    prf.printLine("ZenBSD: enabling interrupts (PIT @ 100 Hz)");
    arch.cpu.enable_interrupts();
}

/// Create process 1 (init) and hand off to userland. Not implemented yet.
fn start_init() void {
    prf.printLine("");
    prf.printLine("ZenBSD: init(8) not implemented; idling.");
}

/// Bring-up checks for the VM and fault paths. Temporary; not part of the
/// NetBSD start-up flow.
fn bringup_selftest() void {
    // Map a physical page at a scratch kernel address and read it back.
    const va: u64 = arch.vmparam.KERNEL_SCRATCH_BASE;
    const pa: u64 = uvm_page.physalloc() orelse return;
    arch.pmap.kenterPa(va, pa, .kernel_rw);
    const cell: *volatile u64 = @ptrFromInt(va);
    cell.* = 0x5a5a_5a5a_5a5a_5a5a;
    prf.print("  vm test:       pa ");
    prf.printHex(pa);
    prf.print(" at va ");
    prf.printHex(va);
    prf.print(" read ");
    prf.printHex(cell.*);
    prf.printLine("");

    // Demand-zero fault: register an unmapped range, then touch it.
    const fault_va: u64 = va + param.PAGE_SIZE;
    uvm_fault.register(fault_va, fault_va + param.PAGE_SIZE);
    const fault_cell: *volatile u64 = @ptrFromInt(fault_va);
    fault_cell.* = 0xdead_beef_cafe_babe;
    prf.print("  fault test:    pa ");
    prf.printHex(arch.pmap.extract(fault_va) orelse 0);
    prf.print(" read ");
    prf.printHex(fault_cell.*);
    prf.printLine("");
}

/// System startup; initialize the world.
pub export fn main() void {
    // Attempt to find the console and initialize it in case of early panic or
    // other messages.
    consinit();

    // Announce the system.
    banner();

    // Initialize the virtual memory system. (NetBSD initializes much more here:
    // timeouts, event counters, the process and lwp tables, the scheduler, ...)
    uvm_init.uvm_init();
    prf.print("  memory:        ");
    prf.printDec(uvm_page.freeCount());
    prf.printLine(" free pages");

    bringup_selftest();

    // Configure the system hardware. This enables interrupts.
    configure();

    // Create process 1 (init).
    start_init();

    // Should not get here; the scheduler is an infinite loop in NetBSD.
    while (true) {
        arch.cpu.idle();
    }
}
