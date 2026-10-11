# Renux

> A modern, portable, Unix-like operating system written entirely in Zig —
> inspired by NetBSD's clean design and portability, but without decades of
> accumulated legacy.

Renux is a from-scratch reimagining of a BSD-style operating system. It keeps
what makes the BSDs great (a coherent, integrated base system; a clean and
readable source tree; portability as a first-class goal) and drops the parts
that only exist because of historical accident.

## Goals

- **100% Zig.** Kernel and base userland in a single memory-safe systems
  language, no C unless strictly unavoidable at an ABI boundary.
- **One integrated system.** Kernel, libc, and userland are developed together
  in one tree, like the BSDs — not a kernel plus an unrelated distribution.
- **Portability by design.** Architecture-specific code lives behind small,
  well-defined interfaces (`sys/arch`), so bringing up a new CPU is a bounded
  task.
- **Modern where it counts.** Async-aware kernel interfaces, capability-style
  process isolation, reproducible builds, no accidental global state.
- **Copyleft.** Free software that stays free: **GPL-2.0-or-later**.

## License

Renux is distributed under the **GNU General Public License, version 2 or (at
your option) any later version** (`GPL-2.0-or-later`). See [`LICENSE`](LICENSE)
for the full text. Every source file carries an
`SPDX-License-Identifier: GPL-2.0-or-later` header.

The "or later" wording keeps the project permanently open while allowing it to
move to a future GPL version without asking every contributor for permission.
Third-party code keeps its own license: the vendored FreeBSD `rtld-elf`, for
instance, remains under its BSD-2-Clause terms.

## Status

Very early, pre-boot bring-up. The tree currently builds a freestanding kernel
image for `amd64`. There is no bootloader integration, paging, or interrupt
handling yet — see the roadmap below.

## Building

Requirements:

- Zig **0.17.0-dev** (see `.zigversion`)
- `gcc` (optionally, to build the Limine host tool once)
- `xorriso` (to build the ISO image)

Build from the repository root:

```sh
zig build buildkernel     # sys/  -> kernel
zig build buildlib        # lib/  -> C library
zig build buildbin        # bin/  -> sh
zig build buildsbin       # sbin/ -> init
zig build builduserland   # bin/ + sbin/
zig build iso             # bootable ISO (kernel + userland)
zig build run             # boot the ISO in QEMU
zig build all             # everything
```

The finished artifacts are collected in the root `zig-out/`:

```
zig-out/bin/kernel
zig-out/bin/init
zig-out/renux.iso
```

Each subproject keeps its own working `zig-out/` (`sys/zig-out`,
`sbin/zig-out`).

Notes:

- Plain `zig build` (root or `sys/`) produces a **debug** kernel (large, with
  full debug info). In `sys/`, add `-Drelease=true` for an optimized image.
- The kernel targets `x86_64-freestanding-none` with `abi=none`,
  `code_model=kernel`, `red_zone=false`, and `pic=false`.

## Repository layout

The tree follows the NetBSD (and FreeBSD `x86/`) conventions so it is familiar
to BSD developers:

```
build.zig              top-level build (drives sys/, lib/, bin/ and sbin/)
sys/                   kernel
  sys_root.zig         kernel root module
  kern/, uvm/, dev/, sys/
  arch/                machine-dependent code
    arch.zig           architecture dispatch (comptime switch)
    x86/               x86-family code shared by all ports
    amd64/             amd64 port (locore, gdt, vector, trap, conf/)
lib/                   C library (a Zig package)
  build.zig            exposes the "libc" module
  libc/                arch/ (MD syscall primitive), sys/ (MI wrappers), stdio/
    libc.ldscript      userland link script
bin/                   user programs
  sh/                  /bin/sh
sbin/                  system programs
  init/                /sbin/init
stand/                 boot support (Limine protocol bindings, config)
tools/                 build helper scripts (get-limine.sh, mkiso.sh)
```

## Status

Working today:

- **Boot:** Limine (higher half), explicit linker script, GDT + TSS, IDT with
  trap handling.
- **Console:** serial plus a graphical raster console (wsfont / rasops / rcons)
  with a block cursor.
- **Memory:** physical page allocator, x86 pmap with user mappings, demand-zero
  page faults.
- **Interrupts:** legacy 8259 PIC and the 8254 PIT at 100 Hz.
- **Init:** FreeBSD-style SYSINIT / mi_startup with a FreeBSD-format boot log.
- **Userland:** ring 3 entry, `int 0x80` system calls, an ELF64 loader, and a
  `/sbin/init` that prints and exits.

Next:

- Processes/LWPs with their own address space (own CR3), `fork`/`exec`, and a
  scheduler.
- `syscall`/`sysret`, a minimal libc, and a shell.
- Drivers (storage, input) and a second architecture to validate `sys/arch`.

## Contributing

The project is at the stage where almost every piece is up for grabs. Open an
issue to discuss a design before sending a large change, and keep all new code
GPL-2.0-or-later with an SPDX header.
