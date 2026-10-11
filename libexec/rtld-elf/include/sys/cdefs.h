#ifndef _SYS_CDEFS_H_
#define _SYS_CDEFS_H_
#define __BEGIN_DECLS
#define __END_DECLS
#define __P(protos) protos
#define __unused __attribute__((unused))
#define __used __attribute__((used))
#define __dead2 __attribute__((noreturn))
#define __pure2 __attribute__((const))
#define __packed __attribute__((packed))
#define __aligned(x) __attribute__((aligned(x)))
#define __printflike(fmt, va) __attribute__((format(printf, fmt, va)))
#define __printf0like(fmt, va) __attribute__((format(printf, fmt, va)))
#define __scanflike(fmt, va) __attribute__((format(scanf, fmt, va)))
#define __restrict restrict
#define __exported
#define __hidden
#define __weak_symbol __attribute__((weak))
#define __gnu_inline inline
#define _Thread_local __thread
#define __always_inline inline __attribute__((always_inline))
#define __noinline __attribute__((noinline))
#define __unreachable() __builtin_unreachable()
#define __predict_true(exp) __builtin_expect((exp), 1)
#define __predict_false(exp) __builtin_expect((exp), 0)
#define __FBSDID(x)
#define __min_size(x) (x)
#define __offsetof(t,f) __builtin_offsetof(t,f)
#define __containerof(ptr, type, field)
#define alloca(x) __builtin_alloca(x)
#define __compiler_membar() __asm __volatile("" ::: "memory")
#define __nonstring
#define __result_use_check
#define nitems(x) (sizeof(x) / sizeof((x)[0]))
#define __DECONST(type, var) ((type)(uintptr_t)(const void *)(var))
#define __DEQUALIFY(type, var) ((type)(uintptr_t)(const volatile void *)(var))
#define __strong_reference(sym, aliassym)
#define __weak_reference(sym, alias)
#endif
