/* Minimal trigger for the tcc-fork arm-gen.c CMP-SBZ bug.
   slen() is a while(s[i]) loop; the loop condition compares a value the
   compiler loaded into a scratch register that is NOT r0, so the emitted
   `cmp rN,#0` lands the scratch reg in CMP's SBZ field (bits 15-12).
   Unfixed tcc: 0xe351N000 (N!=0) -> qemu SIGILL. Fixed tcc: 0xe3510000. */
int slen(char *s) { int i = 0; while (s[i]) i++; return i; }
