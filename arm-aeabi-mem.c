/* EABI mem helpers for the mes + armv7l tcc bootstrap.
 *
 * Under TCC_ARM_EABI, janneke's tcc (tcc-0.9.26-1147-gee75a10c) emits
 * __aeabi_memcpy / __aeabi_memcpy4 / __aeabi_memcpy8 for aligned struct
 * copies, __aeabi_memmove for possibly-overlapping copies, and
 * __aeabi_memset / __aeabi_memclr for zero-init (see tccgen.c copy_struct
 * and init_putz). Neither the mes libc nor tcc's own lib/armeabi.c defines
 * these, so any tcc-compiled program that copies or zero-inits a struct/array
 * fails to link ("Target label __aeabi_memcpy4 is not valid"). x86/riscv64
 * never need them (those backends inline or use plain memcpy).
 *
 * Thin wrappers over the mes libc's memmove/memset (forward-declared here to
 * avoid header dependencies; sizes are size_t == unsigned long on ILP32 arm).
 * Everything routes through memmove so overlap is always safe. NOTE the ARM
 * EABI reordering: __aeabi_memset is (dest, n, c), not (dest, c, n); tcc's
 * init_putz already emits the swapped order for ARM, so this matches.
 *
 * ARM RTABI (IHI0043) says these return void; tcc discards the result anyway.
 */

void *memmove (void *dest, void const *src, unsigned long n);
void *memset (void *s, int c, unsigned long n);

void __aeabi_memcpy  (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }
void __aeabi_memcpy4 (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }
void __aeabi_memcpy8 (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }
void __aeabi_memmove (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }
void __aeabi_memmove4 (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }
void __aeabi_memmove8 (void *dest, void const *src, unsigned long n) { memmove (dest, src, n); }

void __aeabi_memset  (void *dest, unsigned long n, int c) { memset (dest, c, n); }
void __aeabi_memset4 (void *dest, unsigned long n, int c) { memset (dest, c, n); }
void __aeabi_memset8 (void *dest, unsigned long n, int c) { memset (dest, c, n); }

void __aeabi_memclr  (void *dest, unsigned long n) { memset (dest, 0, n); }
void __aeabi_memclr4 (void *dest, unsigned long n) { memset (dest, 0, n); }
void __aeabi_memclr8 (void *dest, unsigned long n) { memset (dest, 0, n); }
