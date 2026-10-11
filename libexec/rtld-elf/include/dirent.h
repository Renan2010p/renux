#ifndef _DIRENT_H_
#define _DIRENT_H_
#include <sys/types.h>
struct dirent { uint64_t d_ino; int64_t d_off; uint16_t d_reclen; uint8_t d_type; uint16_t d_namlen; char d_name[256]; };
typedef struct __dir DIR;
DIR *opendir(const char *);
struct dirent *readdir(DIR *);
int closedir(DIR *);
#endif
#ifndef DT_UNKNOWN
#define DT_UNKNOWN 0
#define DT_DIR 4
#define DT_REG 8
#define DT_LNK 10
#endif
