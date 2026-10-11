#ifndef _SYS_ENDIAN_H_
#define _SYS_ENDIAN_H_
#include <stdint.h>
static __inline uint32_t bswap32(uint32_t x){ return __builtin_bswap32(x); }
static __inline uint64_t bswap64(uint64_t x){ return __builtin_bswap64(x); }
static __inline uint32_t htobe32(uint32_t x){ return bswap32(x); }
static __inline uint32_t htole32(uint32_t x){ return x; }
static __inline uint32_t be32toh(uint32_t x){ return bswap32(x); }
static __inline uint32_t le32toh(uint32_t x){ return x; }
static __inline uint64_t htobe64(uint64_t x){ return bswap64(x); }
static __inline uint64_t htole64(uint64_t x){ return x; }
static __inline uint64_t be64toh(uint64_t x){ return bswap64(x); }
static __inline uint64_t le64toh(uint64_t x){ return x; }
#define htonl(x) htobe32(x)
#define ntohl(x) be32toh(x)
#define htons(x) __builtin_bswap16(x)
#define ntohs(x) __builtin_bswap16(x)
#endif
