#ifndef _ERR_H_
#define _ERR_H_
void err(int, const char *, ...);
void errx(int, const char *, ...);
void warn(const char *, ...);
void warnx(const char *, ...);
#endif
