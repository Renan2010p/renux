/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * wc: count lines, words and bytes, using stdio FILE.
 */

#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("usage: wc file\n");
        return 1;
    }

    FILE *f = fopen(argv[1], "r");
    if (f == 0) {
        printf("wc: cannot open %s\n", argv[1]);
        return 1;
    }

    unsigned long lines = 0;
    unsigned long words = 0;
    unsigned long bytes = 0;
    int inword = 0;
    int c;
    while ((c = fgetc(f)) >= 0) {
        bytes++;
        if (c == '\n') {
            lines++;
        }
        if (c == ' ' || c == '\t' || c == '\n') {
            inword = 0;
        } else if (!inword) {
            inword = 1;
            words++;
        }
    }
    fclose(f);

    printf("%lu %lu %lu %s\n", lines, words, bytes, argv[1]);
    return 0;
}
