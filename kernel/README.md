# The Renux kernel

The Renux kernel is a monolithic, preemptive kernel for amd64, written in Zig
and modelled on FreeBSD and NetBSD. It implements the **FreeBSD/amd64
system-call ABI**, so FreeBSD binaries run on it unchanged.

This document is a map of the kernel source: how the kernel is put
together, how it starts, and where each part lives. Every source file also
begins with a header comment saying what it does and which BSD source it
corresponds to.

## Contents

- [Design principles](#design-principles)
- [Building and testing](#building-and-testing)
- [Startup](#startup)
- [Source layout](#source-layout)
- [Machine-dependent code](#machine-dependent-code)
- [System calls](#system-calls)
- [Processes and scheduling](#processes-and-scheduling)
- [Memory](#memory)
- [File systems and storage](#file-systems-and-storage)
- [Devices and the console](#devices-and-the-console)
- [Debugging](#debugging)
- [Adding code](#adding-code)

## Design principles

- **BSD structure, BSD names.** Files are named after their FreeBSD or NetBSD
  counterparts (`kern_fork.zig` ↔ `sys/kern/kern_fork.c`), so BSD sources,
  man pages and books map directly onto this tree.
- **Machine independence.** Machine-independent code never imports a port's
  files. It reaches the CPU only through
  [`arch/arch.zig`](arch/arch.zig), which selects the port at compile time.
- **Self-registration.** Subsystems and drivers register their own
  initializers with `SYSINIT` and announce their own devices; nothing is
  started from a hand-written list.
- **Honest output.** Every boot message reports something the kernel actually
  did, in FreeBSD's format.
- **Checked interfaces.** Structures shared with programs, the loader or
  devices have their layout checked at compile time
  ([`sys/checks.zig`](sys/checks.zig)).

## Building and testing

The kernel is built by the top-level `build.zig`:

```sh
zig build kernel    # → zig-out/boot/kernel/kernel
zig build test      # host unit tests of the portable parts
zig build run       # boot the whole system in QEMU
```

| Setting | Value | Why |
| --- | --- | --- |
| Target | `x86_64-freestanding-none`, ELF | no host OS underneath |
| Optimisation | always `ReleaseFast` | a debug kernel is many times slower and needs far deeper kernel stacks |
| Code model | `kernel`, no PIC, no red zone | the kernel runs in the top 2 GiB; interrupts may arrive at any instruction |
| SIMD and FPU | disabled (`-mmx -sse... +soft_float`) | user FPU/SIMD state is saved lazily, so kernel use would corrupt it |
| `compiler_rt` | not bundled | the kernel provides its own memory routines ([`arch/amd64/amd64/support.zig`](arch/amd64/amd64/support.zig)) |
| Linker script | [`arch/amd64/conf/kern.ldscript`](arch/amd64/conf/kern.ldscript) | the higher-half layout and the boot-request sections |

The build also hands the kernel three generated inputs:

| Import | Contents |
| --- | --- |
| `vers` | release, branch and git revision, as FreeBSD's `newvers.sh` |
| `rootimage` | the ext2 root image the kernel carries (`MD_ROOT`) |
| `espimage` | the EFI system partition an install writes (installer kernels only) |

## Startup

```
loader (bootloader/efi)
  └─ _start                        arch/amd64/amd64/locore.zig
       ├─ cpu.startup()            control registers
       ├─ gdt.init()               GDT and TSS
       ├─ vector.install()         IDT
       └─ main()                   core/init_main.zig
            └─ mi_startup()        sorts and runs every SYSINIT, in order:
                 SI_SUB_COPYRIGHT   boot flags, console, copyright, version banner
                 SI_SUB_CPU         CPU identification
                 SI_SUB_VM          physical memory, kernel allocator
                 SI_SUB_INTR        interrupt vectors, the syscall entry
                 SI_SUB_DRIVERS     drivers register (consoles, memory disks,
                                    VirtIO, ATA, /dev/null, random, disks)
                 SI_SUB_CONFIGURE   PCI scan, PIC, RTC, keyboard, USB devices,
                                    framebuffer, partitions
                 SI_SUB_VFS         tmpfs and ext2fs register
                 SI_SUB_CLOCKS      the 8254 timer starts ticking
                 SI_SUB_LAST        the root is mounted, /sbin/init is started,
                                    the scheduler runs (never returns)
```

The loader passes a `BootInfo` (memory map, framebuffer, command line); the
kernel reads it through `arch.boot`, the kernel side of the boot protocol in
[`bootloader/arch/amd64/protocol/kernel.zig`](../bootloader/arch/amd64/protocol/kernel.zig).
The same kernel can also be started by Limine.

The root file system is the embedded image, unpacked into tmpfs, unless the
command line names a disk with `vfs.root.mountfrom=ext2fs:/dev/vda2`; then
that partition is mounted, with the image as the fallback.

## Source layout

```
kernel/
  sys_root.zig     the root module: the panic hook, and the list of
                   subsystems compiled in
  core/            the machine-independent kernel (FreeBSD's sys/kern)
  vm/              virtual memory (sys/vm)
  fs/              file systems (sys/fs)
  geom/            disks and partitions (sys/geom)
  dev/             device drivers (sys/dev)
  sys/             kernel headers: the shared types and constants (sys/sys)
  arch/            machine-dependent code
```

### `core/` — the machine-independent kernel

| Files | Subsystem |
| --- | --- |
| `init_main.zig` | startup: `main()`, `mi_startup()`, the root mount, init |
| `kern_proc.zig`, `kern_fork.zig`, `kern_exec.zig`, `exec_elf.zig`, `kern_exit.zig` | processes: table, `fork`, `execve` and the ELF loader, `exit` and `wait` |
| `kern_sched.zig`, `kern_context.zig`, `kern_thr.zig`, `kern_umtx.zig`, `kern_cpuset.zig` | scheduling, context, threads, user mutexes |
| `kern_signal.zig` | signals and job control |
| `kern_prot.zig`, `kern_resource.zig` | credentials, process groups, sessions, resource limits |
| `kern_time.zig`, `subr_clock.zig` | clocks, timers and calendar conversion |
| `kern_descrip.zig`, `sys_generic.zig`, `sys_pipe.zig`, `sys_poll.zig`, `kern_lockf.zig` | file descriptors, `read`/`write`/`ioctl`, pipes, `poll`, record locks |
| `syscalls.zig`, `kern_syscall.zig`, `subr_syscall.zig` | the system-call table, dispatch, argument helpers |
| `vfs_*.zig` | the VFS: lookup, mount, vnode operations, the buffer cache (`vfs_bio`), `getcwd`, the file system calls |
| `tty.zig` | the terminal line discipline and termios |
| `kern_sysctl.zig` | `sysctl(3)` |
| `kern_shutdown.zig` | `reboot(2)`: sync, unmount, halt or reset |
| `subr_prf.zig` | `printf`, `log(9)`, the message buffer, `panic` |
| `subr_bus.zig`, `subr_devsw.zig` | device attachment and the boot-log lines, character-device switch |
| `subr_kmem.zig` | the kernel memory allocator (`kmem(9)`) |
| `kern_sx.zig` | shared/exclusive locks |
| `sys_getrandom.zig` | `getrandom(2)` |

### `vm/` — virtual memory

| File | Role |
| --- | --- |
| `vm_init.zig` | reads the loader's memory map and sets up the page allocator |
| `phys_bitmap.zig` | the physical page bitmap (unit-tested on the host) |
| `vm_page.zig` | allocating and freeing physical pages |
| `vm_fault.zig` | page faults: demand-zero and file-backed pages |
| `vm_mmap.zig` | `mmap`, `munmap`, `mprotect`, `brk` |

### `fs/` and `geom/` — storage

| Path | Role |
| --- | --- |
| `fs/tmpfs/` | the memory file system the root image is unpacked into |
| `fs/ext2fs/` | read-write ext2, as FreeBSD's `ext2fs` |
| `fs/rootimage.zig`, `fs/espimage.zig` | the images embedded in the kernel |
| `geom/geom_disk.zig` | disks as named devices (`/dev/vda`, `/dev/sda`) |
| `geom/geom_part.zig` | MBR and GPT partitions (`/dev/vda1`, ...) |

### `dev/` — drivers

| Path | Device |
| --- | --- |
| `cons.zig`, `tty.zig`, `mem.zig` | the console, the tty devices, `/dev/null`, `/dev/zero`, ... |
| `wscons/`, `rasops/`, `wsfont/` | the graphical console: VT100/xterm emulator, raster operations, the Spleen 8x16 font; `wskbdutil.zig`, the key sequences both keyboards send |
| `fb/` | `/dev/fb0`, FreeBSD's `fbio.h` interface |
| `pckbport/` | the PS/2 keyboard and its keymap |
| `usb/` | USB: the xHCI host controller (`controller/xhci.zig`), the EHCI firmware handoff (`controller/ehci_pci.zig`), device enumeration (`usb_device.zig`) and the boot-protocol keyboard (`input/ukbd.zig`) |
| `ic/` | chips: the 16550 UART (`com`), i8042, i8253, VGA |
| `pci/` | the PCI bus scan |
| `virtio/` | VirtIO: virtqueues, the legacy PCI transport, the block device (`vtblk`) |
| `ata/` | ATA/IDE disks in PIO mode |
| `md/` | memory disks: the embedded images as `/dev/md0`, `/dev/md1` |
| `random/` | `/dev/random`, seeded from RDRAND (`ivy.zig`) |
| `isa/` | ISA bus definitions |

### `sys/` — kernel headers

Types and constants shared across the kernel, and with user programs where
the ABI requires it: `proc`, `vnode`, `mount`, `file`, `namei`, `signal`,
`stat`, `dirent`, `fcntl`, `termios`, `errno`, `sysinit`, `ioccom`, and the
FreeBSD system-call numbers (`syscall.zig`). `addr.zig` defines the
user/kernel address types; `checks.zig` the compile-time layout checks.

## Machine-dependent code

```
arch/
  arch.zig          the dispatch: picks the port for the target CPU
  x86/              code shared by the x86 family
    include/        cpufunc, segments, page-table entries, special registers
    x86/            IDT, interrupts, 8259 PIC, pmap, bus space, console init
    isa/            the 8254 clock and the CMOS real-time clock
    pci/            PCI configuration-space access
  amd64/            the amd64 port
    amd64/          locore, GDT/TSS, trap vectors, traps, context switch,
                    syscall entry, FPU, sysarch, exec, CPU identification
    include/        machine headers: trap frame, ucontext, vmparam, ...
    conf/           files.zig (the port's module manifest), kern.ldscript
```

Machine-independent code imports only `arch/arch.zig` and uses the names it
exports (`arch.cpu`, `arch.pmap`, `arch.trap`, `arch.boot`, ...). Each port
lists its modules in `arch/<port>/conf/files.zig`, as NetBSD's
`files.amd64`. Bringing up a new CPU means writing a new
`arch/<port>/` that provides the same names, plus its case in
`arch/arch.zig` and in `build.zig`.

## System calls

```
user program: syscall
  └─ arch/amd64/amd64/syscall_entry.zig    switch to the kernel stack,
                                           build a trap frame
       └─ core/kern_syscall.zig            dispatch through the table
            └─ core/syscalls.zig           number → handler
                 └─ the handler            in its subsystem (vfs_syscalls,
                                           kern_fork, sys_generic, ...)
```

The numbers are FreeBSD's ([`sys/syscall.zig`](sys/syscall.zig)). As on
FreeBSD, an error returns with the carry flag set and the errno in `rax`.
The return path is `iretq`, shared with interrupts, so signal delivery works
the same way after either.

The kernel can trace a program's system calls (`truss=<command>`; see
[Debugging](#debugging)).

## Processes and scheduling

Processes live in a fixed table ([`core/kern_proc.zig`](core/kern_proc.zig)),
each with its own address space and kernel stack. The scheduler
([`core/kern_sched.zig`](core/kern_sched.zig)) is a round-robin over runnable
processes, preempted by the 100 Hz clock interrupt. A system call that must
wait calls `sleep()` and is resumed by `wakeup()`, as in the BSDs.

## Memory

All physical memory is mapped at a fixed offset in the kernel's address
space (the direct map, `arch.boot.hhdmOffset()`), so the kernel reaches any
physical page without mapping it first. Each process has its own page tables
(`arch/x86/x86/pmap.zig`) that share the kernel half. User memory is
allocated on demand by the page-fault handler. Kernel objects come from
`kmem` ([`core/subr_kmem.zig`](core/subr_kmem.zig)).

## File systems and storage

The VFS (`core/vfs_*.zig`) follows the BSD vnode design: each file system
provides `vfsops` (mount, unmount, statfs) and `vnops` (lookup, read, write,
...), and path lookup (`vfs_lookup.zig`) walks vnodes across mount points.
Disk blocks go through the buffer cache (`vfs_bio.zig`), whose delayed
writes are flushed by a syncer and on shutdown.

## Devices and the console

Drivers attach in `SI_SUB_DRIVERS` and `SI_SUB_CONFIGURE` and announce
themselves through `subr_bus.zig`, which prints the boot-log line
(`vtblk0: <VirtIO Block Adapter> on virtio_pci0`). Character devices are
registered in the device switch (`subr_devsw.zig`) and appear under `/dev`.

The console writes to the serial port and to the framebuffer at once. On the
framebuffer, `dev/wscons/wsemul_vt100.zig` interprets the output as an xterm
would and `dev/rasops/rasops.zig` draws it.

## Debugging

| Kernel argument | Loader setting | Effect |
| --- | --- | --- |
| `-v` | `boot_verbose="YES"`, `boot -v` | verbose boot: `log(LOG_INFO, ...)` messages are shown |
| `-s` | `boot_single="YES"`, `boot -s` | single-user boot: init offers a shell first |
| `console=comconsole` | `console="comconsole"` | serial console only (also `vidconsole`, or both) |
| `vfs.root.mountfrom=ext2fs:/dev/vda2` | the same name | mount a disk partition as the root |
| `truss=<command>` | — | trace the system calls of every process named `<command>` |

The Renux loader builds the kernel command line from its settings
(`bootloader/efi/handoff.zig`); it forwards the first four. `truss=` is
parsed by the kernel ([`core/kern_syscall.zig`](core/kern_syscall.zig)) but
is not forwarded by the loader yet, so it is only reachable from a Limine
`cmdline:`.

`dmesg` shows the message buffer after boot. A panic prints
`!!!! KERNEL PANIC !!!!`, its message and the faulting address on the
console, then halts the CPU.

## Adding code

- **A system call**: write the handler in its subsystem, add it to the table
  in `core/syscalls.zig` under its FreeBSD number, and check any structure it
  shares with user space in `sys/checks.zig`.
- **A driver**: add it under `dev/`, register its initializer with
  `SYSINIT`, announce it through `subr_bus.zig`, and import it from
  `sys_root.zig`.
- **A file system**: provide its `vfsops` and `vnops` under `fs/<name>/`,
  register it with a `SYSINIT` in `SI_SUB_VFS`, and import it from
  `sys_root.zig`.
- **Portable logic** that does not touch hardware: add `test` blocks and list
  the file in the `test` step of `build.zig`.

Follow the style of the surrounding code: explicit types on declarations, a
header comment on every file naming its BSD counterpart, and a `///` comment
on every function.
