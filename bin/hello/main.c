/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * hello: the first C program built against the ZenBSD C library.
 */

#include <unistd.h>

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;

    const char msg[] = "hello from C on ZenBSD\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
