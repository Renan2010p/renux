// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Resetting, halting and powering off an x86 machine.
//
// The Zig counterpart of the shutdown half of FreeBSD's
// sys/x86/x86/cpu_machdep.c (cpu_reset, cpu_halt). Reset pulses the CPU
// reset line through the keyboard controller and falls back to a triple
// fault. Powering off is ACPI's job on FreeBSD; Renux has no ACPI driver
// yet, so under a hypervisor it writes S5 to the PM1a control port that
// QEMU's PC chipsets (PIIX4 and ICH9) and Bochs place there, and otherwise
// just halts.

const bus: type = @import("../../../sys/bus.zig");
const cpufunc: type = @import("../include/cpufunc.zig");

/// Keyboard controller command port and its "pulse reset line" command.
const KBC_CMD_PORT: u64 = 0x64;
const KBC_PULSE_RESET: u8 = 0xfe;

/// PM1a_CNT.SLP_EN with SLP_TYP 0, which QEMU maps to S5 (soft off).
const PM1_SLP_EN: u16 = 0x2000;
const QEMU_PM1A_CNT: u64 = 0x604;
const BOCHS_PM1A_CNT: u64 = 0xb004;

/// Stop this CPU for good.
pub fn cpu_halt() noreturn {
    while (true) {
        cpufunc.disable_interrupts();
        cpufunc.halt();
    }
}

/// Reset the machine.
pub fn cpu_reset() noreturn {
    cpufunc.disable_interrupts();
    bus.bus_space_write_1(bus.BUS_SPACE_IO, KBC_CMD_PORT, 0, KBC_PULSE_RESET);
    // Still here: load an empty IDT and trap, which triple-faults.
    const empty: extern struct { limit: u16, base: u64 } align(1) = .{ .limit = 0, .base = 0 };
    asm volatile (
        \\ lidt (%[p])
        \\ int3
        :
        : [p] "r" (&empty),
    );
    cpu_halt();
}

/// Whether the CPU runs under a hypervisor (CPUID.1:ECX.HV).
fn underHypervisor() bool {
    return (cpufunc.cpuid(1, 0).ecx & (1 << 31)) != 0;
}

/// Turn the machine off. Returns when it cannot.
pub fn cpu_poweroff() void {
    if (!underHypervisor()) return;
    cpufunc.disable_interrupts();
    bus.bus_space_write_2(bus.BUS_SPACE_IO, QEMU_PM1A_CNT, 0, PM1_SLP_EN);
    bus.bus_space_write_2(bus.BUS_SPACE_IO, BOCHS_PM1A_CNT, 0, PM1_SLP_EN);
}
