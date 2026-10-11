/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * ls: list directory contents, using opendir/readdir and stat.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>

int main(int argc, char **argv) {
    int longfmt = 0;
    int ai = 1;
    if (ai < argc && strcmp(argv[ai], "-l") == 0) {
        longfmt = 1;
        ai++;
    }

    const char *path = "/";
    if (ai < argc) {
        path = argv[ai];
    }

    DIR *d = opendir(path);
    if (d == 0) {
        printf("ls: cannot open %s\n", path);
        return 1;
    }

    struct dirent *de;
    while ((de = readdir(d)) != 0) {
        if (longfmt) {
            struct stat st;
            char full[512];
            sprintf(full, "%s/%s", path, de->d_name);
            if (stat(full, &st) == 0) {
                printf("%8lu %s\n", st.st_size, de->d_name);
            } else {
                printf("%8s %s\n", "?", de->d_name);
            }
        } else {
            printf("%s\n", de->d_name);
        }
    }
    closedir(d);
    return 0;
}
