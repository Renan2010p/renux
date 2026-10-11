// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// amd64 machine-dependent module manifest.
//
// This is the Zig counterpart of sys/arch/amd64/conf/files.amd64 in NetBSD: it
// names every machine-dependent module the port contributes, so the arch
// dispatch (sys/arch/arch.zig) presents a complete port to machine-independent
// code. The amd64 port is deliberately thin: the parts it shares with the rest
// of the x86 family live under sys/arch/x86/ and are pulled in here, exactly as
// files.amd64 includes files.x86 in NetBSD.

// Shared x86 modules.
pub const cpu: type = @import("../../x86/include/cpufunc.zig");
pub const bus_space: type = @import("../../x86/x86/bus_space.zig");
pub const consinit: type = @import("../../x86/x86/consinit.zig");
pub const idt: type = @import("../../x86/x86/idt.zig");
pub const pmap: type = @import("../../x86/x86/pmap.zig");
pub const pic: type = @import("../../x86/x86/i8259.zig");
pub const intrdefs: type = @import("../../x86/include/intrdefs.zig");
pub const gdt_defs: type = @import("../../x86/include/gdt.zig");
pub const intr: type = @import("../../x86/x86/intr.zig");
pub const clock: type = @import("../../x86/isa/clock.zig");

// amd64-specific modules.
pub const locore: type = @import("../amd64/locore.zig");
pub const gdt: type = @import("../amd64/gdt.zig");
pub const vector: type = @import("../amd64/vector.zig");
pub const trap: type = @import("../amd64/trap.zig");
pub const swtch: type = @import("../amd64/swtch.zig");
pub const syscall_entry: type = @import("../amd64/syscall_entry.zig");
pub const sysarch: type = @import("../amd64/sysarch.zig");
pub const proc_md: type = @import("../include/proc.zig");
pub const trapframe: type = @import("../include/trap.zig");
pub const vmparam: type = @import("../include/vmparam.zig");

// Boot protocol bindings in use on this port (Limine).
pub const boot: type = @import("limine");

// Force every module (and its exports, e.g. the trap entry) to be analysed.
comptime {
    _ = @import("../../x86/include/cpufunc.zig");
    _ = @import("../../x86/x86/bus_space.zig");
    _ = @import("../../x86/x86/consinit.zig");
    _ = @import("../../x86/x86/idt.zig");
    _ = @import("../../x86/x86/pmap.zig");
    _ = @import("../../x86/x86/i8259.zig");
    _ = @import("../../x86/include/intrdefs.zig");
    _ = @import("../../x86/x86/intr.zig");
    _ = @import("../../x86/isa/clock.zig");
    _ = @import("../amd64/locore.zig");
    _ = @import("../amd64/gdt.zig");
    _ = @import("../amd64/vector.zig");
    _ = @import("../amd64/trap.zig");
    _ = @import("../amd64/swtch.zig");
    _ = @import("../amd64/syscall_entry.zig");
    _ = @import("../amd64/identcpu.zig");
    _ = @import("../amd64/sysarch.zig");
    _ = @import("../include/proc.zig");
    _ = @import("../include/trap.zig");
    _ = @import("../include/vmparam.zig");
    _ = @import("limine");
}
