// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent process context for the amd64 port.
//
// The Zig counterpart of the MD part of NetBSD's sys/arch/amd64/include/proc.h
// (the PCB): the state swtch() preserves across a kernel-thread switch. Only the
// stack pointer is kept here; the callee-saved registers live on that stack, as
// NetBSD's cpu_switchto() leaves them.

pub const Context: type = extern struct {
    rsp: u64,
};
