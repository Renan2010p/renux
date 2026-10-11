// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Machine-dependent process context for the amd64 port.
//
// The Zig counterpart of the MD part of NetBSD's sys/arch/amd64/include/proc.h
// (the PCB): the state swtch() preserves across a kernel-thread switch. The
// callee-saved registers and the resume address are kept in the struct itself,
// so switching does not depend on the kernel stack layout.

pub const Context: type = extern struct {
    /// Stack pointer to load on resume (points above the consumed return word).
    rsp: u64,
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    /// Address to jump to on resume.
    rip: u64,
};
