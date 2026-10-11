#ifndef _SYS_STAT_H_
#define _SYS_STAT_H_
#include <sys/types.h>
struct timespec { time_t tv_sec; long tv_nsec; };
struct stat {
	dev_t st_dev;
	ino_t st_ino;
	nlink_t st_nlink;
	mode_t st_mode;
	int16_t st_padding0;
	uid_t st_uid;
	gid_t st_gid;
	int32_t st_padding1;
	dev_t st_rdev;
	struct timespec st_atim;
	struct timespec st_mtim;
	struct timespec st_ctim;
	struct timespec st_birthtim;
	off_t st_size;
	blkcnt_t st_blocks;
	blksize_t st_blksize;
	uint32_t st_flags;
	uint32_t st_gen;
	int32_t __spare0[10];
};
#define S_IFMT 0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_ISREG(m) (((m)&S_IFMT)==S_IFREG)
#define S_ISDIR(m) (((m)&S_IFMT)==S_IFDIR)
#define S_IXUSR 0000100
#define S_IXGRP 0000010
#define S_IXOTH 0000001
int stat(const char *, struct stat *);
int fstat(int, struct stat *);
int lstat(const char *, struct stat *);
#endif
