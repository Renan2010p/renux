// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project

pub fn startup() void {
    asm volatile ("");
}

pub fn idle() noreturn {
    while (true)
        halt();
}

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn enable_interrupts() void {
    asm volatile ("sti");
}

pub fn disable_interrupts() void {
    asm volatile ("cli");
}
