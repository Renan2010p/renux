/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * syslogd: the system log daemon.
 *
 * It reads the kernel message buffer (klog) and records new lines in
 * /var/log/messages under the "kernel" tag, then polls for more.
 */

#include <syslog.h>
#include <unistd.h>

long klog(char *buf, unsigned long len);

int main(void) {
    static char buf[16384];
    static char line[600];
    unsigned long seen = 0;

    openlog("syslogd", 0, 0);

    for (;;) {
        long n = klog(buf, sizeof(buf));
        if (n > (long)seen) {
            long i = (long)seen;
            long ln = 0;
            while (i < n) {
                char c = buf[i++];
                if (c == '\n' || ln >= (long)sizeof(line) - 1) {
                    line[ln] = 0;
                    if (ln > 0) {
                        syslogMsg(LOG_INFO, "kernel", line);
                    }
                    ln = 0;
                } else {
                    line[ln++] = c;
                }
            }
            seen = (unsigned long)n;
        }
        sleep(1); /* the kernel sleeps us: no CPU is used while waiting */
    }
}
