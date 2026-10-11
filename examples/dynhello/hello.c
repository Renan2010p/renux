/*-
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * A dynamically linked hello: it is linked against libc.so.1 and started by
 * ld-elf.so.1, which resolves malloc/printf/sprintf at run time.
 */

#include <stdio.h>
#include <stdlib.h>

int
main(int argc, char **argv)
{
	(void)argv;
	char *p = malloc(32);
	sprintf(p, "dynamic hello, argc=%d", argc);
	printf("%s\n", p);
	free(p);
	return (0);
}
