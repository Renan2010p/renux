#ifndef _SYS_ELF64_H_
#define _SYS_ELF64_H_
#include <stdint.h>
typedef uint64_t	Elf64_Addr;
typedef uint16_t	Elf64_Half;
typedef uint64_t	Elf64_Off;
typedef int32_t		Elf64_Sword;
typedef uint32_t	Elf64_Word;
typedef uint64_t	Elf64_Xword;
typedef int64_t		Elf64_Sxword;
typedef struct { unsigned char e_ident[16]; Elf64_Half e_type, e_machine; Elf64_Word e_version; Elf64_Addr e_entry; Elf64_Off e_phoff, e_shoff; Elf64_Word e_flags; Elf64_Half e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx; } Elf64_Ehdr;
typedef struct { Elf64_Word p_type, p_flags; Elf64_Off p_offset; Elf64_Addr p_vaddr, p_paddr; Elf64_Xword p_filesz, p_memsz, p_align; } Elf64_Phdr;
typedef struct { Elf64_Word sh_name, sh_type; Elf64_Xword sh_flags; Elf64_Addr sh_addr; Elf64_Off sh_offset; Elf64_Xword sh_size; Elf64_Word sh_link, sh_info; Elf64_Xword sh_addralign, sh_entsize; } Elf64_Shdr;
typedef struct { Elf64_Word st_name; unsigned char st_info, st_other; Elf64_Half st_shndx; Elf64_Addr st_value; Elf64_Xword st_size; } Elf64_Sym;
typedef struct { Elf64_Addr r_offset; Elf64_Xword r_info; } Elf64_Rel;
typedef struct { Elf64_Addr r_offset; Elf64_Xword r_info; Elf64_Sxword r_addend; } Elf64_Rela;
typedef struct { Elf64_Sxword d_tag; union { Elf64_Xword d_val; Elf64_Addr d_ptr; } d_un; } Elf64_Dyn;
#define ELFMAG0 0x7f
#define ELFMAG1 'E'
#define ELFMAG2 'L'
#define ELFMAG3 'F'
#define ELFCLASS64 2
#define ELFDATA2LSB 1
#define EV_CURRENT 1
#define ET_EXEC 2
#define ET_DYN 3
#define EM_X86_64 62
#define PT_LOAD 1
#define PT_DYNAMIC 2
#define PT_INTERP 3
#define PT_PHDR 6
#define PT_GNU_RELRO 0x6474e552
#define PT_TLS 7
#define PF_X 1
#define PF_W 2
#define PF_R 4
#define DT_NULL 0
#define DT_NEEDED 1
#define DT_PLTRELSZ 2
#define DT_PLTGOT 3
#define DT_HASH 4
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_RELA 7
#define DT_RELASZ 8
#define DT_RELAENT 9
#define DT_STRSZ 10
#define DT_SYMENT 11
#define DT_INIT 12
#define DT_FINI 13
#define DT_SONAME 14
#define DT_RPATH 15
#define DT_SYMBOLIC 16
#define DT_REL 17
#define DT_RELSZ 18
#define DT_RELENT 19
#define DT_PLTREL 20
#define DT_DEBUG 21
#define DT_TEXTREL 22
#define DT_JMPREL 23
#define DT_INIT_ARRAY 25
#define DT_FINI_ARRAY 26
#define DT_INIT_ARRAYSZ 27
#define DT_FINI_ARRAYSZ 28
#define DT_RUNPATH 29
#define DT_FLAGS 30
#define DT_GNU_HASH 0x6ffffef5
#define DT_VERSYM 0x6ffffff0
#define DT_VERNEED 0x6ffffffe
#define DT_VERNEEDNUM 0x6fffffff
#define DT_VERDEF 0x6ffffffc
#define DT_VERDEFNUM 0x6ffffffd
#define DT_RELACOUNT 0x6ffffff9
#define DT_RELCOUNT 0x6ffffffa
#endif
typedef uint32_t Elf32_Word;
typedef uint16_t Elf32_Half;
typedef uint32_t Elf32_Addr;
typedef uint32_t Elf32_Off;
typedef struct { Elf64_Half vn_version; Elf64_Half vn_cnt; Elf64_Word vn_file; Elf64_Word vn_aux; Elf64_Word vn_next; } Elf64_Verneed;
typedef struct { Elf64_Word vna_hash; Elf64_Half vna_flags; Elf64_Half vna_other; Elf64_Word vna_name; Elf64_Word vna_next; } Elf64_Vernaux;
typedef struct { Elf64_Half vd_version; Elf64_Half vd_flags; Elf64_Half vd_ndx; Elf64_Half vd_cnt; Elf64_Word vd_hash; Elf64_Word vd_aux; Elf64_Word vd_next; } Elf64_Verdef;
typedef struct { Elf64_Word vda_name; Elf64_Word vda_next; } Elf64_Verdaux;
typedef Elf64_Xword Elf64_Relr;
typedef struct { Elf64_Addr r_offset; Elf64_Xword r_info; Elf64_Sxword r_addend; } Elf64_Rela_use;
typedef struct { Elf64_Word n_namesz; Elf64_Word n_descsz; Elf64_Word n_type; } Elf64_Nhdr;
