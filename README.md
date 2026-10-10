# ZenBSD

> A modern, portable, Unix-like operating system written entirely in Zig —
> inspired by NetBSD's clean design and portability, but without decades of
> accumulated legacy.

ZenBSD is a from-scratch reimagining of a BSD-style operating system. It keeps
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
- **Copyleft.** Free software that stays free: **GPL-2.0-only**.

## License

ZenBSD is distributed under the **GNU General Public License, version 2 only**
(`GPL-2.0-only`). See [`LICENSE`](LICENSE) for the full text. Every source file
carries an `SPDX-License-Identifier: GPL-2.0-only` header.

> If you would rather allow "version 2 or later", change the SPDX headers to
> `GPL-2.0-or-later` and update this section accordingly.

## Status

Very early, pre-boot bring-up. The tree currently builds a freestanding kernel
image for `amd64`. There is no bootloader integration, paging, or interrupt
handling yet — see the roadmap below.

## Building

Requirements:

- Zig **0.17.0-dev** (see `.zigversion`)

```sh
cd sys
zig build -Drelease=true   # optimized kernel -> sys/zig-out/bin/kernel
```

Notes:

- Plain `zig build` produces a **debug** kernel (large, with full debug info).
  Add `-Drelease=true` for an optimized image.
- The build targets `x86_64-freestanding-none` with `abi=none`,
  `code_model=kernel`, `red_zone=false`, and `pic=false`.

## Repository layout

The tree deliberately mirrors the NetBSD layout so it is familiar to BSD
developers:

```
sys/
  build.zig            kernel build definition
  index.zig            kernel root module (wires everything together)
  arch/                machine-dependent code
    arch.zig           architecture dispatch (comptime switch)
    amd64/             amd64 port
      machdep.zig      per-arch module aggregation
      amd64/           NetBSD-style machine directory
        cpu.zig        CPU primitives (halt, interrupt flags, ...)
        locore.zig     low-level entry point
  kern/                machine-independent kernel core
    init_main.zig      kernel entry (main -> idle)
  dev/                 device drivers
    ic/vga/vga.zig     ISA/VGA console driver (stub)
  conf/                kernel configuration
  sys/                 kernel headers / shared interfaces
```

## Roadmap

1. **Boot.** Limine (or Multiboot2) header, linker script, long-mode entry,
   minimal GDT/IDT, and a bootable ISO.
2. **Memory.** Physical page allocator, virtual memory / paging, kernel heap.
3. **Interrupts & time.** IDT + exception handling, APIC, timers.
4. **Scheduling & processes.** Threads, context switching, syscall ABI.
5. **Drivers.** Console, serial, storage, input.
6. **Userland & libc.** Minimal libc, init, shell.
7. **Portability.** Bring-up of a second architecture to validate the
   `sys/arch` abstractions.

## Contributing

The project is at the stage where almost every piece is up for grabs. Open an
issue to discuss a design before sending a large change, and keep all new code
GPL-2.0-only with an SPDX header.
