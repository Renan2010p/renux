#ifndef _MACHINE_ATOMIC_H_
#define _MACHINE_ATOMIC_H_
#include <stdint.h>
static __inline int atomic_load_acq_int(volatile u_int *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static __inline void atomic_store_rel_int(volatile u_int *p, u_int v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static __inline int atomic_cmpset_acq_int(volatile u_int *p, u_int old, u_int new) { u_int e = old; return __atomic_compare_exchange_n(p, &e, new, 0, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE); }
static __inline int atomic_cmpset_acq_ptr(volatile uintptr_t *p, uintptr_t old, uintptr_t new) { uintptr_t e = old; return __atomic_compare_exchange_n(p, &e, new, 0, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE); }
static __inline void atomic_add_acq_int(volatile u_int *p, u_int v) { __atomic_fetch_add(p, v, __ATOMIC_ACQUIRE); }
static __inline u_int atomic_fetchadd_int(volatile u_int *p, u_int v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static __inline void atomic_add_32(volatile uint32_t *p, uint32_t v) { __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static __inline void atomic_add_int(volatile u_int *p, u_int v) { __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static __inline void atomic_subtract_int(volatile u_int *p, u_int v) { __atomic_fetch_sub(p, v, __ATOMIC_SEQ_CST); }
static __inline uint32_t atomic_fetchadd_32(volatile uint32_t *p, uint32_t v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
#endif
#define atomic_add_rel_int(p,v) __atomic_fetch_add((p),(v),__ATOMIC_SEQ_CST)
