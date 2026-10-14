# Renux

> A modern, portable, Unix-like operating system written entirely in Zig —
> inspired by NetBSD's and FreeBSD clean design and portability, but without decades of
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

The source tree holds only Renux's own code. The FreeBSD userland that runs
on Renux (its base system and packages) is fetched from FreeBSD's servers by
`tools/get-freebsd.sh` and `tools/get-freebsd-pkg.sh`, and keeps its own
licenses; it is never committed here.

## ABI

Renux's native system-call and C ABI is the **FreeBSD/amd64 ABI**: the same
system-call numbers, the `syscall` instruction with carry-flag error reporting,
the `Elf_Auxinfo` layout, the process-entry convention (`%rdi` points at argc),
and the structures programs see (`stat`, `dirent`, `rlimit`, `timespec`, ...).
Dynamically linked programs use FreeBSD's own dynamic linker, `ld-elf.so.1`,
from the fetched base system.

A binary built for FreeBSD/amd64 should therefore run on Renux unchanged. That
is what lets the project reuse the FreeBSD userland, and it is the road to
running large programs such as Xorg:

1. FreeBSD **static** binaries — done (`/rescue/echo` runs).
2. FreeBSD **dynamic** binaries (real `ld-elf.so.1` + `libc.so.7`).
3. Threads (`thr_self`, `_umtx_op`, `thr_wake`) and `kqueue`.
4. Sockets and shared memory.
5. The drivers a graphical stack needs (input, DRM/KMS).

## Status

See the status section near the end of this file.

## Building

Requirements:

- Zig **0.17.0-dev** (see `.zigversion`)
- `gcc` (optionally, to build the Limine host tool once)
- `xorriso` and `mtools`/`dosfstools` (to build the ISO image)
- QEMU, and OVMF (`edk2-x86_64-code.fd`) for `run-efi`

Build from the repository root:

```sh
zig build buildkernel     # sys/  -> kernel
zig build buildlib        # lib/  -> C library
zig build buildbin        # bin/  -> sh
zig build buildsbin       # sbin/ -> init
zig build builduserland   # bin/ + sbin/
zig build rootfs          # the root image embedded in the kernel
zig build bootloader      # stand/ -> BOOTX64.EFI (the Renux loader)
zig build iso             # bootable ISO (UEFI: Renux loader, BIOS: Limine)
zig build run             # boot the ISO in QEMU (BIOS, serial console)
zig build run-efi         # boot through UEFI and the Renux loader, in a window
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

`zig build run` and `run-efi` attach a persistent disk, `sys/disk.img` (a
sparse 1 GiB ext2 image made by `tools/mkdisk.sh` on the first run and never
touched again). Renux sees it as `/dev/vtbd0` and mounts it on `/home` from
`/etc/fstab`; files there survive a reboot. Shut down with `poweroff`,
`reboot` or `shutdown` so the file system is marked clean; on the host,
`e2fsck -f sys/disk.img` checks it and `debugfs sys/disk.img` looks inside.

Notes:

- The kernel is always built **ReleaseFast** (`sys/build.zig`); boot with
  `-v` for verbose messages and `truss=<command>` to trace a program's system
  calls.
- The kernel targets `x86_64-freestanding-none` with `abi=none`,
  `code_model=kernel`, `red_zone=false`, and `pic=false`.

## Booting

Renux boots the way FreeBSD does, with its own loader in place of
`/boot/loader`:

- **UEFI**: `\EFI\BOOT\BOOTX64.EFI` is the Renux loader (`stand/efi/loader`
  for the firmware side, `stand/common` for the menu, `loader.conf` and the
  `OK` prompt). It reads `/boot/defaults/loader.conf` and `/boot/loader.conf`,
  shows the boot menu ("Welcome to Renux": multi/single user, the loader
  prompt, reboot, console, kernel selection, boot options) with an autoboot
  countdown, loads `/boot/kernel/kernel` and reports each segment
  (`text=0x... data=0x...+0x...`), the EFI framebuffer and the entry point.
  The variables keep FreeBSD's names (`autoboot_delay`, `boot_single`,
  `boot_verbose`, `console`, `kernel`, `kernels`, `beastie_disable`,
  `loader_logo`, ...).
- **BIOS**: Limine loads the same kernel, as a fallback.

The loader passes FreeBSD's boot flags to the kernel: `-s` boots single user
(init offers a shell, then continues to multi-user when it exits), `-v` a
verbose boot log.

## Boot log

The kernel's boot log follows FreeBSD's format, so it reads like a FreeBSD
dmesg: the banner, the version line generated by `sys/build.zig` from git (as
FreeBSD's newvers.sh: `Renux 0.1-CURRENT main-n96-6627e9f4b9c7 GENERIC amd64`
for a reproducible build, or with `#0`, the build date and `user@host:path`
with `-Ddevbuild=true`), the CPU report with decoded feature flags, then one
`name<unit>: <description> <resources> on <parent>` line per attached device.
Every line reports something the system actually did.

- Drivers announce their own attachment through `sys/kern/subr_bus.zig`; there
  are no hard-coded device lines.
- Internal progress messages (`log(LOG_INFO, ...)`, allocator and filesystem
  registration, ...) are only shown with **`boot -v`**: add `-v` (or
  `boot_verbose=YES`) to the kernel command line, e.g. `cmdline: -v` in
  `limine.conf`.
- `dmesg` shows the message buffer, starting at `---<<BOOT>>---`; loader-stage
  output (`Loading kernel...`, the spinner) is console-only.
- The time of day comes from the CMOS real-time clock (`atrtc0`).

## Console and framebuffer

The graphical console is the boot framebuffer driven by `sys/dev/rasops`
(15/16, 24 and 32 bpp) and a VT100/xterm emulator (`sys/dev/wscons`) that
runs with `TERM=xterm`: 16/256/24-bit colours, bold, underline and reverse
video, deferred autowrap, scrolling regions, the alternate screen, and UTF-8
shown through the font's Latin-1 glyphs, with box-drawing and block
characters drawn by geometry. Only cells whose appearance changes are
repainted, and scrolling moves pixels instead of redrawing glyphs.

`/dev/fb0` speaks FreeBSD's `fbio.h` ioctls (`FBIOGTYPE`,
`FBIO_GETLINEWIDTH`, `FBIO_GETRGBOFFS`, ...) with FreeBSD's request numbers,
and can be mmap(2)ed. A program that draws on it puts the console in
`KD_GRAPHICS` mode with `KDSETMODE` so the text console keeps out, and back in
`KD_TEXT` to have the text repainted; if it exits without doing so, the console
takes the screen back itself. `/bin/fbdraw` is a small example.

## Repository layout

The tree follows the NetBSD (and FreeBSD `x86/`) conventions so it is familiar
to BSD developers:

```
build.zig              top-level build (drives sys/, lib/, bin/ and sbin/)
sys/                   kernel
  sys_root.zig         kernel root module
  kern/, vm/, fs/, dev/, sys/
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
stand/                 boot loader and boot support
  common/              MI loader: menu, loader.conf, OK prompt, brand/logo
  efi/loader/          UEFI loader (BOOTX64.EFI)
  defaults/loader.conf /boot/defaults/loader.conf
  arch/amd64/          Renux boot protocol (shared with the kernel)
  amd64/               Limine bindings and config (BIOS fallback)
tools/                 build helper scripts (get-limine.sh, mkrootfs.sh, mkiso.sh)
```

## Status

Working today:

- **Boot:** the Renux UEFI loader (or Limine on BIOS) loads the kernel and nothing else; the root
  filesystem is embedded in the kernel (FreeBSD's `MD_ROOT`) and unpacked at
  boot. Explicit linker script, GDT + TSS, IDT with trap handling; FreeBSD-style
  SYSINIT / mi_startup, boot log and `Loading kernel...` spinner.
- **Console:** serial plus a graphical raster console (wsfont / rasops / rcons)
  with an underline cursor.
- **Memory:** physical page allocator, x86 pmap with per-process address spaces,
  demand-zero page faults, `brk` and file-backed `mmap`.
- **Interrupts:** legacy 8259 PIC and the 8254 PIT at 100 Hz, preemptive
  scheduling over a process table.
- **Processes:** fork/exec/wait/exit, signals, sysarch, and the FreeBSD/amd64
  system-call ABI (`syscall`/`iretq`).
- **VFS:** tmpfs root, file and directory system calls (with the `*at`
  family relative to a directory descriptor), hard and symbolic links,
  `nmount`/`unmount`/`statfs`/`getfsstat`, tty/termios.
- **Storage:** a PCI bus scan, the VirtIO block driver (`vtblk`, legacy
  interface), disks as `/dev/vtbdN`, a buffer cache with delayed writes and
  a syncer, and a read-write ext2 file system (FreeBSD's `ext2fs`), checked
  clean by `e2fsck`. FreeBSD's `mount`, `umount`, `df`, `sync` and
  `reboot`/`halt`/`poweroff`/`shutdown` run unchanged.
- **Userland:** FreeBSD's own (fetched): login with PAM, sh, the base
  utilities, ee, and bash and GNU nano from packages, dynamically linked
  against FreeBSD's `libc.so.7`. Renux's own: init, a Zig libc, native tools
  and a standalone C toolchain (`tools/zcc`).

Next:

- FreeBSD dynamic binaries (real `ld-elf.so.1` + `libc.so.7`).
- Threads and `kqueue`; then sockets and shared memory.
- Drivers for a graphical stack (input, DRM/KMS) — the road to Xorg.

## Contributing

The project is at the stage where almost every piece is up for grabs. Open an
issue to discuss a design before sending a large change, and keep all new code
GPL-2.0-or-later with an SPDX header.
