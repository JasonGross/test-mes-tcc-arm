/* Freestanding ARM driver: calls slen() (compiled separately by tcc) on a
   10-char string and exits with the length as the status code. No libc, so
   the ONLY tcc-compiled code in the image is slen() — isolating the bug.
   Exit uses the OABI syscall form (svc #(0x900000+__NR)) to avoid pinning r7. */
extern int slen(char *s);
void _start(void) {
  static char msg[] = "abcdefghij";      /* 10 non-NUL chars */
  int n = slen(msg);                     /* buggy cmp is inside this loop */
  register int r0 asm("r0") = n;         /* status = 10 if it runs */
  asm volatile ("svc #0x900001" :: "r"(r0) : "memory");  /* OABI __NR_exit=1 */
}
