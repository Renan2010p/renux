#ifndef _ELF_HINTS_H_
#define _ELF_HINTS_H_
#include <stdint.h>
#define ELFHINTS_MAGIC 0x746e6845
#define ELFHINTS_VERSION 1
struct elfhints_hdr {
	uint32_t magic;
	uint32_t version;
	uint32_t strtab;
	uint32_t strtab_size;
	uint32_t dirlist;
	uint32_t dirlistlen;
};
#endif
