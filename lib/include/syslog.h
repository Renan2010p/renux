/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 The Renux Project
 *
 * System logging.
 */

#ifndef _ZENBSD_SYSLOG_H_
#define _ZENBSD_SYSLOG_H_

#define LOG_EMERG 0
#define LOG_ALERT 1
#define LOG_CRIT 2
#define LOG_ERR 3
#define LOG_WARNING 4
#define LOG_NOTICE 5
#define LOG_INFO 6
#define LOG_DEBUG 7

void openlog(const char *ident, int option, int facility);
void closelog(void);
void syslog(int priority, const char *fmt, ...);
void syslogMsg(int priority, const char *ident, const char *message);

#endif /* _ZENBSD_SYSLOG_H_ */
