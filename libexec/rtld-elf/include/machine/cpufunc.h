static __inline void cpu_spinwait(void) { __asm __volatile("pause"); }
static __inline void __pause(void) { __asm __volatile("pause"); }
static __inline void do_cpuid(u_int ax, u_int *p) {
	__asm __volatile("cpuid" : "=a"(p[0]), "=b"(p[1]), "=c"(p[2]), "=d"(p[3]) : "a"(ax), "c"(0));
}
static __inline void cpuid_count(u_int leaf, u_int subleaf, u_int *p) {
	__asm __volatile("cpuid" : "=a"(p[0]), "=b"(p[1]), "=c"(p[2]), "=d"(p[3]) : "a"(leaf), "c"(subleaf));
}
static __inline void wrfsbase(unsigned long base) { __asm __volatile("wrfsbase %0" :: "r"(base)); }
static __inline unsigned long rdfsbase(void) { unsigned long v; __asm __volatile("rdfsbase %0" : "=r"(v)); return v; }
static __inline unsigned long rdtsc(void) { unsigned int a, d; __asm __volatile("rdtsc" : "=a"(a), "=d"(d)); return ((unsigned long)d<<32)|a; }
