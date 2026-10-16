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
  well-defined interfaces (`kernel/arch`), so bringing up a new CPU is a bounded
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
`tools/fetch.zig` (`zig build fetch`), and keeps its own licenses; it is never
committed here.

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
- QEMU, and OVMF (`edk2-x86_64-code.fd`) for `run` and `run-efi`

The ISO is written by `tools/mkiso.zig`, so no `xorriso` or `mtools` are
needed; the ISO is UEFI-only (the Renux loader), with no BIOS/Limine path.
The FreeBSD userland is fetched by `tools/fetch.zig` (`zig build fetch`), so
no `curl`, `tar`, `xz`, `sha256sum` or `openssl` are needed either.

Still needed from the host while the tree is ported to Zig: `readelf`
(binutils), which `tools/mkrootfs.sh` uses to read the fetched userland's
`DT_NEEDED` entries (a Zig ELF reader is next). The ext2 images are already
made by `tools/mkfs.zig` -- no `mke2fs`.

Build from the repository root, with one `build.zig` for the whole system:

```sh
zig build                 # kernel, loader and native userland (the default)
zig build kernel          # kernel/  -> zig-out/boot/kernel/kernel
zig build loader          # stand/   -> zig-out/boot/loader.efi
zig build userland        # userland/ -> zig-out/userland/, zig-out/lib/libc.a
zig build fetch           # the FreeBSD userland (base + packages) -> tools/freebsd/
zig build iso             # zig-out/renux.iso (UEFI, written by tools/mkiso.zig)
zig build installer-iso   # zig-out/renux-installer.iso (the install medium)
zig build run             # boot the ISO in QEMU (UEFI, serial console)
zig build run-efi         # boot through UEFI and the Renux loader, in a window
zig build run-hda         # boot with an IDE disk (qemu -hda, /dev/sda)
zig build test            # host unit tests
```

`zig-out/` is laid out like the installed system:

```
zig-out/boot/kernel/kernel    the kernel, with the root image embedded
zig-out/boot/loader.efi       the UEFI loader
zig-out/userland/             native programs at their system paths
zig-out/lib/libc.a            the C library, for tools/zcc
zig-out/renux.iso             the bootable ISO
```

The root image is made by `tools/mkrootfs.sh` from `zig-out/userland` plus
the FreeBSD userland when it has been fetched (`zig build fetch`), and
embedded in the kernel. `-Dmdroot=false` builds a kernel without it.

`zig build run` and `run-efi` attach a persistent disk, `disk.img` at the
top of the tree (a sparse 1 GiB ext2 image made by `tools/mkdisk.sh` on the
first run and never touched again, even by `rm -rf zig-out`). Renux sees it
as `/dev/vda` and mounts it on `/home` from `/etc/fstab`; `zig build run-hda`
uses the legacy IDE channel instead, where the disk is `/dev/sda`. Files there
survive a reboot. Shut down with `poweroff`, `reboot` or `shutdown` so the
file system is marked clean; on the host, `e2fsck -f disk.img` checks it and
`debugfs disk.img` looks inside.

Notes:

- The kernel is always built **ReleaseFast** (`build.zig`); boot with
  `-v` for verbose messages and `truss=<command>` to trace a program's system
  calls.
- The kernel targets `x86_64-freestanding-none` with `abi=none`,
  `code_model=kernel`, `red_zone=false`, and `pic=false`.

## Booting

Renux boots the way FreeBSD does, with its own loader in place of
`/boot/loader`:

- **UEFI** (the only path): `\EFI\BOOT\BOOTX64.EFI` is the Renux loader
  (`stand/efi/loader` for the firmware side, `stand/common` for the menu,
  `loader.conf` and the `OK` prompt). It reads `/boot/defaults/loader.conf`
  and `/boot/loader.conf`, shows the boot menu ("Welcome to Renux": multi/single
  user, the loader prompt, reboot, console, kernel selection, boot options)
  with an autoboot countdown, loads `/boot/kernel/kernel` and reports each
  segment (`text=0x... data=0x...+0x...`), the EFI framebuffer and the entry
  point. The variables keep FreeBSD's names (`autoboot_delay`, `boot_single`,
  `boot_verbose`, `console`, `kernel`, `kernels`, `beastie_disable`,
  `loader_logo`, ...).

The ISO is UEFI-only and written by `tools/mkiso.zig`: a FAT16 image with the
loader and the kernel, wrapped in an ISO 9660 volume whose El Torito boot
catalog points the firmware at it. There is no `xorriso`, no `mtools`, and no
BIOS/Limine path.

By default the kernel mounts its embedded root image. When the loader passes
`vfs.root.mountfrom="ext2fs:/dev/vda2"` (a `loader.conf` variable), the kernel
mounts that disk partition as the root instead, and falls back to the image if
it cannot -- so an installed system boots from its disk.

## Installing

`zig build installer-iso` writes `zig-out/renux-installer.iso`. Boot it, log in
as root, and run `renux-installer` (a `dialog` menu, as bsdinstall has) or
`renux-installer -y /dev/vda`. The installer writes a GPT with an EFI system
partition (FAT) and an ext2 root, copies the images the kernel carries
(`/dev/md0` is the root image, `/dev/md1` the ESP image with the loader, the
kernel and the `loader.conf`), and writes the installed system's `/etc/fstab`.
Reboot with the medium removed and the disk boots on its own.

The loader passes FreeBSD's boot flags to the kernel: `-s` boots single user
(init offers a shell, then continues to multi-user when it exits), `-v` a
verbose boot log.

## Boot log

The kernel's boot log follows FreeBSD's format, so it reads like a FreeBSD
dmesg: the banner, the version line generated by `build.zig` from git (as
FreeBSD's newvers.sh: `Renux 0.1-CURRENT main-n96-6627e9f4b9c7 GENERIC amd64`
for a reproducible build, or with `#0`, the build date and `user@host:path`
with `-Ddevbuild=true`), the CPU report with decoded feature flags, then one
`name<unit>: <description> <resources> on <parent>` line per attached device.
Every line reports something the system actually did.

- Drivers announce their own attachment through `kernel/core/subr_bus.zig`; there
  are no hard-coded device lines.
- Internal progress messages (`log(LOG_INFO, ...)`, allocator and filesystem
  registration, ...) are only shown with **`boot -v`**: add `-v` (or
  `boot_verbose=YES`) to the kernel command line, e.g. `boot_verbose="YES"` in
  `loader.conf`.
- `dmesg` shows the message buffer, starting at `---<<BOOT>>---`; loader-stage
  output (`Loading kernel...`, the spinner) is console-only.
- The time of day comes from the CMOS real-time clock (`atrtc0`).

## Console and framebuffer

The graphical console is the boot framebuffer driven by `kernel/dev/rasops`
(15/16, 24 and 32 bpp) and a VT100/xterm emulator (`kernel/dev/wscons`) that
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

Renux keeps its own layout: the kernel in `kernel/` (its machine-independent
heart in `kernel/core/`), everything that runs in user mode in `userland/`,
laid out as it is installed, and the boot loader in `stand/`. Only Renux's
own code lives here; the FreeBSD userland is fetched (see `tools/`).

```
build.zig              the build of the whole system
kernel/                the kernel
  sys_root.zig         kernel root module
  core/                processes, scheduling, signals, system calls, VFS,
                       buffer cache (FreeBSD's sys/kern; kern_*.zig, vfs_*.zig)
  vm/                  physical pages, faults, mmap
  fs/                  tmpfs, ext2fs
  dev/                 drivers: console, tty, framebuffer, PCI, VirtIO, ...
  geom/                disks
  sys/                 kernel headers (proc, vnode, mount, signal, ...)
  arch/                machine-dependent code
    arch.zig           architecture dispatch (comptime switch)
    x86/               x86-family code shared by all ports
    amd64/             amd64 port (locore, gdt, vector, trap, conf/)
userland/              user mode, as installed
  lib/                 the Zig C library and C startup (libc, csu, include/)
  bin/                 /bin: sh and native tools
  sbin/                /sbin: init
  usr/bin/             /usr/bin: login, stat
  libexec/             /usr/libexec: getty
  etc/                 /etc: rc, rc.d, fstab, motd
stand/                 boot loader and boot support
  common/              MI loader: menu, loader.conf, OK prompt, brand/logo
  efi/loader/          UEFI loader (BOOTX64.EFI)
  defaults/loader.conf /boot/defaults/loader.conf
  arch/amd64/          Renux boot protocol (shared with the kernel)
  amd64/               Limine bindings and config (legacy BIOS path, unused
                       by `zig build iso`)
tools/                 build programs: mkiso.zig (the UEFI ISO writer),
                       mkfs.zig (the ext2 writer), fetch.zig (the FreeBSD
                       userland downloader), mkrootfs.sh, mkdisk.sh, the zcc
                       C toolchain and pkgtool; get-freebsd*.sh and
                       get-limine.sh are the replaced shell predecessors
```

## Status

Working today:

- **Boot:** the Renux UEFI loader loads the kernel and nothing else; the root
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
  interface), disks as Linux names them (`/dev/vda`, `/dev/sda`, partitions
  `/dev/vda1`, ...; `kernel/geom` reads MBR and GPT), an ATA/IDE (PIO) driver
  for `qemu -hda` and real IDE hardware, a buffer cache with delayed writes and
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
