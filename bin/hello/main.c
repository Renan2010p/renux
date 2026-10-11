/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * hello: exercise the ZenBSD C library.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <errno.h>

int main(int argc, char **argv, char **envp) {
    (void)envp;

    char *heap = malloc(64);
    strcpy(heap, "the C heap works");
    printf("hello from C on ZenBSD: %s\n", heap);
    free(heap);

    printf("isatty(0)=%d\n", isatty(0));

    char b[64];
    snprintf(b, sizeof(b), "snprintf:%d/%s", 7, "ok");
    printf("%s\n", b);

    int n = 0;
    char word[32];
    sscanf("42 hello", "%d %s", &n, word);
    printf("sscanf: %d %s\n", n, word);

    FILE *f = fopen("/etc/rc", "r");
    if (f != 0) {
        fseek(f, 0, 2);
        printf("etc/rc size=%ld\n", ftell(f));
        fclose(f);
    }

    int c;
    while ((c = getopt(argc, argv, "ab:")) != -1) {
        printf("opt %c arg %s\n", c, optarg ? optarg : "-");
    }

    if (open("/nope", 0, 0) < 0) {
        printf("errno=%d %s\n", errno, strerror(errno));
    }
    return 0;
}
