/*-
 * SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * Minimal startup for a dynamically linked program.  The kernel enters the
 * dynamic linker (ld-elf.so.1); rtld relocates this program and jumps to its
 * entry point with %rdi pointing at argc on the initial stack, following the
 * FreeBSD rtld convention.  _exit is resolved from the shared libc by rtld.
 */

extern int main(int, char **, char **);
extern void _exit(int) __attribute__((noreturn));

void
_start(long *sp)
{
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	char **envp = argv + argc + 1;

	_exit(main(argc, argv, envp));
}
