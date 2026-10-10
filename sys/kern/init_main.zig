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
const prf: type = @import("subr_prf.zig");

pub export fn main() void {
    arch.consinit.consinit();

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

    prf.printLine("");
    prf.printLine("ZenBSD: IDT self-test (int3):");
    arch.cpu.breakpoint();
    prf.printLine("ZenBSD: trap handler returned.");

    prf.printLine("");
    prf.printLine("ZenBSD: entering idle.");
    arch.cpu.idle();
}
