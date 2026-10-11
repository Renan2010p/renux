/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * Minimal ctype declarations (C locale).
 */

#ifndef _ZENBSD_CTYPE_H_
#define _ZENBSD_CTYPE_H_

int isdigit(int c);
int isspace(int c);
int isalpha(int c);
int isalnum(int c);
int isupper(int c);
int islower(int c);
int isxdigit(int c);
int toupper(int c);
int tolower(int c);

#endif /* _ZENBSD_CTYPE_H_ */
