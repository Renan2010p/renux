// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Kernel main: system startup.
//
// This follows FreeBSD's model: instead of a hand-ordered sequence of calls,
// subsystems register initializers with SYSINIT at a (subsystem, order)
// priority, and mi_startup() sorts and runs them. main() therefore reduces to
// "run the registered initializers, then idle". The copyright/trademark/version
// announcement and the console and init bring-up are registered here, in the
// same spirit as FreeBSD's sys/kern/init_main.c.

const arch: type = @import("../arch/arch.zig");
const rasops: type = @import("../dev/rasops/rasops.zig");
const sysinit: type = @import("../sys/sysinit.zig");
const kern_exec: type = @import("kern_exec.zig");
const uvm_page: type = @import("../uvm/uvm_page.zig");
const param: type = @import("../sys/param.zig");
const prf: type = @import("subr_prf.zig");

/// Copyright notice (cf. FreeBSD's sys/conf/copyright).
const copyright: []const u8 =
    "Copyright (c) 2026 The ZenBSD Project.  All rights reserved.\n\n";

/// Trademark notice (cf. FreeBSD's sys/conf/trademark).
const trademark: []const u8 =
    "ZenBSD is a trademark of The ZenBSD Project.\n\n";

/// Build identification, printed as "version machine" then the compiler line,
/// as FreeBSD's print_version() does.
const version: []const u8 =
    "ZenBSD 0.1 (GENERIC) #0: Sat Oct 10 12:00:00 UTC 2026\n" ++
    "\tbuild@zenbsd:/usr/src/sys/amd64/compile/GENERIC amd64\n" ++
    "ZenBSD clang version 22.1.8 (https://github.com/llvm/llvm-project.git)\n";

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

/// Find and initialise the console, for early messages (NetBSD's consinit()).
fn consinit(_: ?*const anyopaque) callconv(.c) void {
    arch.consinit.consinit(bootRaster());
}

/// Print the copyright notice.
fn announce(_: ?*const anyopaque) callconv(.c) void {
    prf.print(copyright);
}

/// Print the trademark notice.
fn printTrademark(_: ?*const anyopaque) callconv(.c) void {
    prf.print(trademark);
}

/// Print the version and compiler identification.
fn printVersion(_: ?*const anyopaque) callconv(.c) void {
    prf.print(version);
}

/// Configure the system hardware. This enables interrupts (FreeBSD's
/// SI_SUB_CONFIGURE; NetBSD's configure()).
fn configure(_: ?*const anyopaque) callconv(.c) void {
    prf.printLine("com0 at isa0 port 0x3f8-0x3ff: ns16550a");
    prf.printLine("i8254 at isa0 port 0x40-0x43");
    if (arch.boot.framebuffer(0)) |fb| {
        prf.print("wsdisplay0 at vga0: console ");
        prf.printDec(fb.width);
        prf.print("x");
        prf.printDec(fb.height);
        prf.print("x");
        prf.printDec(fb.bpp);
        prf.printLine("");
    }
    prf.printLine("ZenBSD: enabling interrupts (PIT @ 100 Hz)");
    arch.cpu.enable_interrupts();
}

/// Create process 1 (init): load the init executable passed as a boot module,
/// set up its stack, and enter ring 3 (NetBSD's start_init()).
fn start_init(_: ?*const anyopaque) callconv(.c) void {
    const module = arch.boot.module(0) orelse {
        prf.printLine("init: no init module provided");
        return;
    };
    const address = module.address orelse {
        prf.printLine("init: module has no address");
        return;
    };
    const image: []const u8 = @as([*]const u8, @ptrCast(address))[0..@intCast(module.size)];

    const result = kern_exec.exec(image) orelse {
        prf.printLine("init: not an executable image");
        return;
    };

    // Map the initial user stack.
    var va: u64 = arch.vmparam.USER_STACK_TOP - arch.vmparam.USER_STACK_SIZE;
    while (va < arch.vmparam.USER_STACK_TOP) : (va += param.PAGE_SIZE) {
        const pa: u64 = uvm_page.physalloc() orelse return;
        arch.pmap.enterUser(va, pa, .user_rw);
    }

    // Kernel stack the CPU switches to when control returns from ring 3.
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return;
    const kpa: u64 = uvm_page.physalloc() orelse return;
    arch.gdt.setKernelStack(hhdm + kpa + param.PAGE_SIZE);

    prf.print("init: entering user mode at ");
    prf.printHex(result.entry);
    prf.printLine("");

    // The SysV ABI expects rsp % 16 == 8 at function entry (a call has pushed
    // the return address). iretq pushes no such word, so bias the stack by 8.
    arch.locore.enterUser(result.entry, arch.vmparam.USER_STACK_TOP - 8);
}

comptime {
    sysinit.SYSINIT("sysinit_console", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FIRST, consinit, null);
    sysinit.SYSINIT("sysinit_announce", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_SECOND, announce, null);
    sysinit.SYSINIT("sysinit_trademark", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_THIRD, printTrademark, null);
    sysinit.SYSINIT("sysinit_version", sysinit.SI_SUB_COPYRIGHT, sysinit.SI_ORDER_FOURTH, printVersion, null);
    sysinit.SYSINIT("sysinit_configure", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_MIDDLE, configure, null);
    sysinit.SYSINIT("sysinit_start_init", sysinit.SI_SUB_LAST, sysinit.SI_ORDER_FIRST, start_init, null);
}

/// Run every registered initializer, in (subsystem, order) order
/// (FreeBSD's mi_startup()).
pub fn mi_startup() void {
    const list: []sysinit.Sysinit = sysinit.entries();
    sysinit.sort(list);
    for (list) |*entry| {
        entry.func(entry.udata);
    }
}

/// System startup; run the registered initializers.
pub export fn main() void {
    mi_startup();

    // Should not get here; the scheduler is an infinite loop in NetBSD/FreeBSD.
    while (true) {
        arch.cpu.idle();
    }
}
