#ifndef _LINK_H_
#define _LINK_H_
#include <sys/types.h>
#include <stdint.h>
typedef struct link_map {
	caddr_t		l_base;
	const char	*l_name;
	const void	*l_ld;
	struct link_map	*l_next, *l_prev;
	caddr_t		l_addr;
	const char	*l_refname;
} Link_map;
struct r_debug {
	int		r_version;
	struct link_map *r_map;
	void		(*r_brk)(struct r_debug *, struct link_map *);
	enum { RT_CONSISTENT, RT_ADD, RT_DELETE } r_state;
	void		*r_ldbase;
};
struct dl_phdr_info {
	uint64_t dlpi_addr;
	const char *dlpi_name;
	const void *dlpi_phdr;
	uint16_t dlpi_phnum;
	uint64_t dlpi_adds;
	uint64_t dlpi_subs;
	size_t dlpi_tls_modid;
	void *dlpi_tls_data;
};
#define LA_SER_ORIGIN 0x01
#define LA_SER_LIBPATH 0x02
#define LA_SER_RUNPATH 0x04
#define LA_SER_CONFIG 0x08
#define LA_SER_DEFAULT 0x10
#define LA_SER_SECURE 0x20
#define R_DEBUG_VERSION 1
int dl_iterate_phdr(int (*)(struct dl_phdr_info *, size_t, void *), void *);
#endif
