// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The amd64 part of the UEFI loader.
//
// The machine-independent loader (bootloader/efi) imports this file as the
// "loader_md" module. Everything it needs to know about the CPU goes through
// the names below, so a new port of the loader provides
// bootloader/arch/<machine>/efi/md.zig with the same declarations:
//
//   ELF_MACHINE           the e_machine the kernel image must carry
//   KERNEL_ALIGN          the physical alignment of the kernel image
//   PageTableLayout       what the kernel's initial page tables must map
//   buildPageTables       build them; returns the value for the root register
//   initialStackPointer   the stack pointer to enter the kernel with
//   enterKernel           switch to the kernel's page tables and stack, jump
//
// This is the counterpart of FreeBSD's stand/efi/loader/arch/amd64.

const std: type = @import("std");
const elf64: type = @import("elf64_renux.zig");
const tramp: type = @import("amd64_tramp.zig");

/// The kernel is an x86-64 ELF.
pub const ELF_MACHINE: std.elf.EM = .X86_64;

/// The kernel image is placed on a 2 MiB boundary, so 2 MiB pages map it.
pub const KERNEL_ALIGN: u64 = elf64.LARGE_PAGE_SIZE;

pub const PageTableLayout: type = elf64.PageTableLayout;
pub const buildPageTables = elf64.buildPageTables;
pub const initialStackPointer = tramp.initialStackPointer;
pub const enterKernel = tramp.enterKernel;
