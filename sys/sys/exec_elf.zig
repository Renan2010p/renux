// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// ELF64 on-disk structures.
//
// This is the Zig counterpart of NetBSD's sys/sys/exec_elf.h (FreeBSD puts the
// same structures in sys/sys/elf64.h and drives them from imgact_elf.c). Only
// what the loader reads is defined.

/// ELF magic, the first four bytes of e_ident.
pub const ELFMAG: [4]u8 = .{ 0x7f, 'E', 'L', 'F' };

/// Operating system / ABI identifications (e_ident[EI_OSABI]).
pub const ELFOSABI_NONE: u8 = 0;
pub const ELFOSABI_FREEBSD: u8 = 9;

pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;

/// Object file types.
pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;

/// Machine types.
pub const EM_X86_64: u16 = 62;

/// Program header types.
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;

/// Program header flags.
pub const PF_X: u32 = 0x1;
pub const PF_W: u32 = 0x2;
pub const PF_R: u32 = 0x4;

/// ELF file header.
pub const Ehdr: type = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// ELF program header.
pub const Phdr: type = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};
