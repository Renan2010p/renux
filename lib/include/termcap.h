/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 The ZenBSD Project
 *
 * termcap declarations.
 */

#ifndef _ZENBSD_TERMCAP_H_
#define _ZENBSD_TERMCAP_H_

int tgetent(char *bp, const char *name);
char *tgetstr(const char *name, char **area);
int tgetnum(const char *name);
int tgetflag(const char *name);
char *tgoto(const char *cm, int destcol, int destrow);
int tputs(const char *cp, int affcnt, int (*outc)(int));

#endif /* _ZENBSD_TERMCAP_H_ */
