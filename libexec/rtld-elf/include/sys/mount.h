#ifndef _SYS_MOUNT_H_
#define _SYS_MOUNT_H_
#define MNT_RDONLY 0x00000001
#define MNT_NOEXEC 0x00000008
struct statfs {
	uint32_t f_version;
	uint32_t f_type;
	uint64_t f_flags;
	uint64_t f_bsize;
	uint64_t f_iosize;
	uint64_t f_blocks;
	uint64_t f_bfree;
	uint64_t f_bavail;
	uint64_t f_files;
	uint64_t f_ffree;
	char f_fstypename[16];
	char f_mntonname[1024];
	char f_mntfromname[1024];
};
int statfs(const char *, struct statfs *);
int fstatfs(int, struct statfs *);
#endif
