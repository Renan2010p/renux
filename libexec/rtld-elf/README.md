# rtld-elf (port placeholder)

These sources are vendored verbatim from FreeBSD's `libexec/rtld-elf` (the
dynamic linker, `ld-elf.so.1`), under its BSD-2-Clause licence, so that Renux
can run **dynamically linked** FreeBSD binaries. Renux is GPL-2.0; BSD code may
be incorporated under GPL-2.0 (one-way), keeping the original copyright.

They are **not built yet**: this directory is the port's starting point.

## What Renux already provides (the kernel half)

`sys/kern/exec_elf.zig` and `sys/kern/kern_exec.zig` now handle dynamic
executables:

- `ET_DYN` images load at a chosen base (`exec_elf.load(pmap, src, base)`).
- `PT_INTERP` is read and the interpreter is mapped at `INTERP_BASE`.
- The initial stack carries an **aux vector**: `AT_PAGESZ`, `AT_PHDR`,
  `AT_PHENT`, `AT_PHNUM`, `AT_ENTRY`, `AT_BASE`, `AT_UID`/`EUID`/`GID`/`EGID`.
- `sysarch(2)` sets the FS base (the thread pointer) for TLS.

So the kernel hands control to an interpreter with everything a `ld.so`
needs.

## What remains to build this port

1. **Syscalls** rtld reaches for: `open`, `read`, `pread`, `close`, `mmap`,
   `mprotect`, `munmap`, `fstat` (FreeBSD `struct stat`), `__sysctl`,
   `thr_self`, `sigaction`/`sigprocmask` (FreeBSD `sigset_t`), `_umtx_op`,
   `getdirentries`, and the FreeBSD `auxv` layout.
2. **Headers**: rtld includes `<sys/*.h>`. A small FreeBSD-compatible subset
   (or the `rtld-libc` shim, already vendored) must satisfy it.
3. **Build**: compile the `.c` files with `zig cc` for
   `x86_64-freestanding-none` against the Renux headers, and link `ld-elf.so.1`
   as a static ET_DYN with the `amd64/rtld_start.S` entry.
4. **A shared libc** (`libc.so.7`) for the program to link against.

The realistic first milestone is an interpreter that loads a trivial dynamic
executable, resolves its relocations and transfers control to it.
