#ifndef _MACHINE_TLS_H_
#define _MACHINE_TLS_H_
#include <stddef.h>
struct dtv_slot { void *dtvs_tls; };
struct dtv { unsigned long dtv_gen; int dtv_size; struct dtv_slot dtv_slots[1]; };
struct tcb { struct tcb *tcb_self; struct dtv *tcb_dtv; };
#define TCB_SIZE (sizeof(struct tcb))
#define TLS_TCB_SIZE (sizeof(struct tcb))
#define TLS_TCB_ALIGN 16
#define TLS_DTV_OFFSET 0
struct tcb *_tcb_get(void);
#endif
