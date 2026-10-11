/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The Renux Project
 *
 * logger: append its arguments to the system log.
 */

#include <syslog.h>
#include <string.h>

int main(int argc, char **argv) {
    char msg[256];
    msg[0] = 0;
    for (int i = 1; i < argc; i++) {
        if (i > 1) {
            strcat(msg, " ");
        }
        strcat(msg, argv[i]);
    }

    openlog("logger", 0, 0);
    syslog(LOG_INFO, "%s", msg);
    closelog();
    return 0;
}
