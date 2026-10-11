/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * dmesg: print the kernel message buffer.
 */

long klog(char *buf, unsigned long len);
long write(int fd, const void *buf, unsigned long n);

int main(void) {
    char buf[16384];
    long n = klog(buf, sizeof(buf));
    if (n > 0) {
        write(1, buf, (unsigned long)n);
    }
    return 0;
}
