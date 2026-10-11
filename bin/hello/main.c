/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * hello: the first C program built against the ZenBSD C library.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;

    char *buf = malloc(64);
    if (buf == 0) {
        printf("malloc failed\n");
        return 1;
    }
    strcpy(buf, "the C heap works");
    printf("hello from C on ZenBSD: %s\n", buf);
    printf("1024 = %d, 0x%x, %lu\n", 1024, 255, 4096UL);
    free(buf);

    char b[64];
    sprintf(b, "sprintf:%s=%d", "x", 42);
    printf("[%s]\n", b);
    printf("[%8lu]\n", 4096UL);
    return 0;
}
