#define AMD64_GET_FSBASE 129
#define AMD64_SET_FSBASE 128
#define AMD64_SET_TLSBASE 0x100
#define P_OSREL_TLSBASE 0
int sysarch(int, void *);
struct amd64_set_fsbase_args { unsigned long fsbase; };
