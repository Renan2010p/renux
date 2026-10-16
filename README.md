# Renux

**A modern, portable, Unix-like operating system written in Zig.**

Renux is a from-scratch BSD-style operating system. It keeps what makes the
BSDs great — a coherent, integrated base system, a clean and readable source
tree, and portability as a first-class goal — and drops the parts that exist
only because of historical accident. Its design follows FreeBSD and NetBSD
closely, and it speaks the **FreeBSD/amd64 ABI**, so FreeBSD's own userland
runs on it unchanged.

```
Renux 0.1-CURRENT main-n109-3b99578caf41 GENERIC amd64
CPU: QEMU Virtual CPU version 2.5+ (3693.09-MHz K8-class CPU)
real memory  = 530329600 (505 MB)
vtblk0: <VirtIO Block Adapter> on virtio_pci0
Trying to mount root from tmpfs:/dev/md0 []...
Starting syslogd.

Renux/amd64 (renux) (ttyv0)

login:
```

---

## Contents

- [Highlights](#highlights)
- [Goals](#goals)
- [Quick start](#quick-start)
- [Building](#building)
- [Running](#running)
- [Installing to a disk](#installing-to-a-disk)
- [How Renux boots](#how-renux-boots)
- [The console](#the-console)
- [FreeBSD compatibility](#freebsd-compatibility)
- [Writing programs for Renux](#writing-programs-for-renux)
- [Source tree](#source-tree)
- [Status and roadmap](#status-and-roadmap)
- [Contributing](#contributing)
- [License](#license)

## Highlights

- **Its own UEFI boot loader** with FreeBSD's boot menu, `loader.conf` and
  `OK` prompt.
- **A FreeBSD-shaped kernel**: `SYSINIT`/`mi_startup`, a FreeBSD-format boot
  log, `newbus`-style device attachment, `log(9)`, `sysctl`, a VFS with tmpfs
  and read-write ext2, a buffer cache, and the FreeBSD system-call table.
- **Real storage**: PCI, VirtIO block and ATA/IDE drivers, MBR and GPT
  partitions, and a persistent disk.
- **FreeBSD's userland, unmodified**: login with PAM, `sh`, the base
  utilities, `ee`, plus `bash` and GNU `nano` from FreeBSD packages.
- **100% Zig**: the kernel, the loader, the C library, every native program,
  the system startup and every build tool are Zig. The tree has no shell
  scripts and no C, and the build needs no `xorriso`, `mtools`, `mke2fs`,
  `readelf`, `curl` or `tar`.

## Goals

- **100% Zig.** Kernel, base userland, system startup and build tools in one
  memory-safe systems language.
- **One integrated system.** Kernel, libc and userland are developed together
  in one tree, as in the BSDs — not a kernel plus an unrelated distribution.
- **Portability by design.** Machine-dependent code lives behind small,
  explicit interfaces (`kernel/arch/arch.zig`, `bootloader/arch/<machine>/`),
  so bringing up a new CPU is a bounded task.
- **Modern where it counts.** Reproducible builds, no accidental global state,
  and room for async-aware kernel interfaces and capability-style isolation.
- **Copyleft.** Free software that stays free: GPL-2.0-or-later.

## Quick start

```sh
zig build fetch     # download the FreeBSD userland (once)
zig build run       # build everything and boot it in QEMU, on the serial console
```

Log in as `root`. Shut down with `poweroff`.

## Building

### Requirements

| Tool | Used for |
| --- | --- |
| Zig **0.17.0-dev** (exact version in [`.zigversion`](.zigversion)) | everything |
| QEMU (`qemu-system-x86_64`) | the `run*` steps |
| OVMF / EDK II (`edk2-x86_64-code.fd`) | UEFI firmware for QEMU; override with `-Dovmf=<path>` |

### Build steps

All steps run from the repository root.

| Command | Produces |
| --- | --- |
| `zig build` | the kernel, the loader and the native userland (the default) |
| `zig build kernel` | `zig-out/boot/kernel/kernel`, with the root image embedded |
| `zig build loader` | `zig-out/boot/loader.efi` (`\EFI\BOOT\BOOTX64.EFI`) |
| `zig build userland` | `zig-out/userland/`, the native programs |
| `zig build fetch` | the FreeBSD base system and packages, in `tools/freebsd/` |
| `zig build iso` | `zig-out/renux.iso`, a UEFI-bootable ISO |
| `zig build installer-iso` | `zig-out/renux-installer.iso`, the install medium |
| `zig build test` | runs the host unit tests |

### Options

| Option | Effect |
| --- | --- |
| `-Ddevbuild=true` | stamp the kernel with the build date and `user@host:path`, like a FreeBSD developer kernel |
| `-Dmdroot=false` | build a kernel without the embedded root image |
| `-Dovmf=<path>` | the UEFI firmware image for the `run*` steps |

### Notes

- The kernel is always built **ReleaseFast**, for `x86_64-freestanding-none`
  with `code_model=kernel`, no red zone, no PIC and no SIMD. Debugging does
  not need a debug build: boot with `-v` for verbose messages (see
  [`kernel/README.md`](kernel/README.md#debugging) for the other kernel
  arguments).
- The kernel identifies itself from git, as FreeBSD's `newvers.sh` does
  (`main-n109-3b99578caf41`). The date is the commit's, so the same tree
  always builds the same kernel.
- The root image is made by `tools/mkrootfs.zig` from `zig-out/userland`
  plus the FreeBSD userland (when fetched): it follows each FreeBSD program's
  `DT_NEEDED` entries to install exactly the libraries it uses, and packs the
  tree with the ext2 writer `tools/mkfs.zig`.

## Running

| Command | Machine |
| --- | --- |
| `zig build run` | QEMU `q35`, UEFI, serial console in the terminal |
| `zig build run-efi` | the same, in a graphical window |
| `zig build run-hda` | QEMU `pc` with the disk on the legacy IDE channel |

Every run attaches a **persistent disk**: `disk.img` at the top of the tree, a
sparse 1 GiB ext2 image made on the first run and never touched by the build
again (not even by `rm -rf zig-out`). Renux sees it as `/dev/vda` (`/dev/sda`
with `run-hda`) and mounts it on `/home` from `/etc/fstab`, so files there
survive a reboot.

Shut down with `poweroff`, `reboot` or `shutdown` so the file system is marked
clean. On the host, `e2fsck -f disk.img` checks it and `debugfs disk.img`
looks inside.

## Installing to a disk

1. `zig build installer-iso` and boot `zig-out/renux-installer.iso`.
2. Log in as `root` and run `renux-installer` (a `dialog` menu, as
   bsdinstall has), or `renux-installer -y /dev/vda` to install without
   questions.
3. Reboot with the medium removed.

The installer writes a GPT with an EFI system partition (FAT) and an ext2
root, copies the images the installer kernel carries (`/dev/md0`, the root
image; `/dev/md1`, the ESP with the loader, the kernel and a `loader.conf`),
and writes the installed system's `/etc/fstab`.

## How Renux boots

```
UEFI firmware
  └─ \EFI\BOOT\BOOTX64.EFI            the Renux loader (bootloader/)
       ├─ reads /boot/defaults/loader.conf, /boot/loader.conf
       ├─ boot menu, autoboot countdown, OK prompt
       ├─ loads /boot/kernel/kernel (ELF), builds its page tables
       └─ ExitBootServices, jump to the kernel with a BootInfo
            └─ kernel: _start → mi_startup() runs every SYSINIT
                 ├─ console, CPU, memory, interrupts, devices
                 ├─ root file system: the embedded image, or a disk
                 └─ /sbin/init: ldconfig, mount -a, syslogd → getty → login
```

**The loader** is FreeBSD's `/boot/loader` rewritten in Zig. It shows the
"Welcome to Renux" menu (multi- or single-user, the loader prompt, reboot,
console and kernel selection, boot options), reports each kernel segment it
loads (`text=0x... data=0x...+0x...`) and the framebuffer it hands over. Its
variables keep FreeBSD's names — `autoboot_delay`, `boot_single`,
`boot_verbose`, `console`, `kernel`, `kernels`, `beastie_disable`,
`loader_logo` — and it passes FreeBSD's boot flags (`-s`, `-v`) on the kernel
command line. See [`bootloader/efi/main.zig`](bootloader/efi/main.zig).

**The root file system** is embedded in the kernel (FreeBSD's `MD_ROOT`) and
unpacked into tmpfs at boot. When `loader.conf` sets
`vfs.root.mountfrom="ext2fs:/dev/vda2"`, the kernel mounts that partition
instead, and falls back to the image if it cannot — so an installed system
boots from its disk.

**The ISO** is UEFI-only and written by `tools/mkiso.zig`: a FAT16 image
holding the loader and the kernel, inside an ISO 9660 volume whose El Torito
catalog points the firmware at it.

**The boot log** reads like a FreeBSD `dmesg`: the banner, the version line,
the CPU with its decoded feature flags, then one
`name<unit>: <description> <resources> on <parent>` line per attached device.
Each line reports something the system actually did; drivers announce
themselves through `kernel/core/subr_bus.zig`. Internal progress messages
appear only with `boot -v`. `dmesg` shows the message buffer from
`---<<BOOT>>---`.

## The console

The graphical console is the boot framebuffer, drawn by
`kernel/dev/rasops` (15/16, 24 and 32 bpp) under a VT100/xterm emulator
(`kernel/dev/wscons`) that runs with `TERM=xterm`: 16, 256 and 24-bit
colour, bold, underline and reverse video, scrolling regions, the alternate
screen, and UTF-8 through the font's Latin-1 glyphs, with box-drawing and
block characters drawn by geometry. Only cells that change are repainted, and
scrolling moves pixels rather than redrawing glyphs.

`/dev/fb0` speaks FreeBSD's `fbio.h` ioctls (`FBIOGTYPE`,
`FBIO_GETLINEWIDTH`, `FBIO_GETRGBOFFS`, ...) and can be `mmap(2)`ed. A
program drawing on it switches the console to `KD_GRAPHICS` with `KDSETMODE`
and back to `KD_TEXT` when done; if it exits without doing so, the console
takes the screen back. `/bin/fbdraw` is a small example.

## FreeBSD compatibility

Renux's native system-call and C ABI **is** the FreeBSD/amd64 ABI: the same
system-call numbers, the `syscall` instruction with carry-flag error
reporting, the `Elf_Auxinfo` layout, the process-entry convention (`%rdi`
points at `argc`), and the same structures (`stat`, `dirent`, `rlimit`,
`timespec`, ...). Dynamically linked programs use FreeBSD's own
`ld-elf.so.1` from the fetched base system.

A binary built for FreeBSD/amd64 therefore runs on Renux unchanged. This is
what lets Renux reuse the FreeBSD userland today, and it is the road to large
programs such as Xorg.

The FreeBSD userland is **not** part of this tree. `zig build fetch`
(`tools/fetch.zig`) downloads the base system and packages from FreeBSD's
servers — HTTPS, xz/zstd, tar, SHA-256 and the package catalog's RSA
signature, all with Zig's standard library — and they keep their own
licenses.

## Writing programs for Renux

**In Zig, natively.** A program in `userland/` imports the Renux C library
and the C startup (`libc`, `csu`); add it to the `programs` list in
`build.zig` and it is built and installed in the root image.
[`userland/bin/cat/main.zig`](userland/bin/cat/main.zig) is a small example.

**In C, or any language, as a FreeBSD program.** Renux runs FreeBSD/amd64
binaries, so build for FreeBSD — Zig cross-compiles to it with no FreeBSD
system at hand:

```sh
zig cc --target=x86_64-freebsd -O2 -o hello hello.c
zig build-exe -target x86_64-freebsd -lc hello.zig
```

Such a program links dynamically against FreeBSD's `libc.so.7`, which the
root image carries once `zig build fetch` has run. Copy it to the persistent
disk (`/home`) or add it to the root image, and run it.

## Source tree

```
build.zig            the build of the whole system
kernel/              the kernel                         → kernel/README.md
  core/              processes, scheduler, signals, system calls, VFS
  vm/                physical pages, page faults, mmap
  fs/                tmpfs, ext2fs, the embedded images
  dev/               drivers: console, tty, framebuffer, PCI, VirtIO, ATA, ...
  geom/              disks and partitions
  sys/               kernel headers: proc, vnode, mount, signal, ...
  arch/              machine-dependent code: x86/ (shared), amd64/
bootloader/          the UEFI boot loader
  common/            menu, loader.conf, OK prompt, brand and logo
  efi/               UEFI, machine-independent: console, files, ELF, hand-off
  arch/amd64/        page tables and kernel entry, the boot protocol, Limine
  defaults/          /boot/defaults/loader.conf
userland/            user mode, laid out as installed
  lib/               the Zig C library and C startup (libc, csu, include/)
  bin/ sbin/         /bin and /sbin: sh, init, the native tools, the installer
  usr/bin/ libexec/  /usr/bin and /usr/libexec: login, stat, getty
  etc/               /etc: fstab, motd
tools/               host programs used by the build (all Zig)
  fetch.zig          the FreeBSD userland downloader
  mkrootfs.zig       builds the root image
  mkfs.zig           the ext2 writer (also a module of mkrootfs and mkdisk)
  mkdisk.zig         creates the persistent disk
  mkiso.zig          the UEFI ISO and FAT writer
  pkgtool/           a FreeBSD package catalog reader
```

Every directory names its files after their FreeBSD or NetBSD counterparts
(`kern_fork.zig`, `vfs_lookup.zig`, `subr_prf.zig`, ...), so the BSD sources
and documentation map directly onto the Renux tree.

## Status and roadmap

**Working today**

| Area | What runs |
| --- | --- |
| Boot | the Renux UEFI loader; GDT, TSS and IDT; `SYSINIT`/`mi_startup`; the embedded root image |
| Console | serial and a graphical raster console (wsfont, rasops, VT100/xterm) |
| Memory | physical page allocator, per-process address spaces, demand-zero faults, `brk`, file-backed `mmap` |
| Interrupts | 8259 PIC, 8254 PIT at 100 Hz, preemptive scheduling |
| Processes | `fork`, `exec`, `wait`, `exit`, signals and job control, `sysarch`, the FreeBSD/amd64 system-call ABI |
| Files | tmpfs and read-write ext2 (clean under `e2fsck`), the `*at` system calls, hard and symbolic links, pipes, `poll`, `nmount`/`unmount`/`statfs`/`getfsstat`, tty and termios |
| Storage | PCI bus scan, VirtIO block (`/dev/vda`), ATA/IDE PIO (`/dev/sda`), MBR and GPT, a buffer cache with delayed writes and a syncer |
| Userland | FreeBSD's login, sh, base utilities, `mount`, `df`, `reboot`/`shutdown`, ee, bash and nano; Renux's own init, libc, native tools and installer |

**Next**

1. FreeBSD dynamic binaries end to end (`ld-elf.so.1` and `libc.so.7`).
2. Threads (`thr_self`, `_umtx_op`, `thr_wake`) and `kqueue`.
3. Sockets and shared memory.
4. The drivers a graphical stack needs (input, DRM/KMS) — the road to Xorg.

## Contributing

Almost every part of the system is open for work. Please open an issue to
discuss a design before sending a large change.

- Keep each change focused, and make sure `zig build`, `zig build test` and
  a boot with `zig build run` still succeed.
- Follow the style of the surrounding code: explicit types on declarations,
  a header comment on every file explaining what it is and which BSD source
  it corresponds to, and a `///` comment on every function.
- Every new file is GPL-2.0-or-later and starts with the SPDX header:

  ```zig
  // SPDX-License-Identifier: GPL-2.0-or-later
  // Copyright (C) 2026 The Renux Project
  ```

## License

Renux is free software, distributed under the **GNU General Public License,
version 2 or (at your option) any later version** (`GPL-2.0-or-later`). See
[`LICENSE`](LICENSE) for the full text.

The "or later" wording keeps the project permanently open while letting it
move to a future GPL version without asking every contributor for permission.

The tree holds only Renux's own code. FreeBSD is a registered trademark of
The FreeBSD Foundation; the Renux loader's brand and logo are Renux's own
artwork and do not use FreeBSD's.
