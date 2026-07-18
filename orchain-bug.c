/* bug #11 reproducer (the shape tcc patch 0006 works around).
 *
 * tcc's arm-gen.c builds every VFP instruction word by OR-ing a "double
 * precision" bit into an opcode base, where the bit is an inline conditional:
 *
 *     #define T2CPR(t) (((t) & VT_BTYPE) != VT_FLOAT ? 0x100 : 0)
 *     o(0xEEB80A40 | r2 | T2CPR(t));     // a NON-FIRST OR-term
 *
 * Stock MesCC drops the OR-terms that PRECEDE an inline conditional term, so a
 * MesCC-built tcc keeps only the conditional's value (0x100) and emits a bare
 * 0x00000100 where the VFP opcode should be.  This 8-line analogue reproduces
 * exactly that: the base (0xEEB80A00 | 0x40) is dropped.
 *
 * A correct compiler returns 0xEEB80B40 (exit 0).  Stock MesCC returns 0x100
 * (exit 2 = base dropped).  See orchain-fixed.c for patch 0006's rewrite.
 *
 * main() also prints the value it actually got (f(3)=0x........) via raw
 * write(2) -- see emit_hex below -- so the CI log shows the miscompiled value
 * directly, not just an exit-code signature.
 */

int write(int fd, char *buf, int n);   /* raw syscall wrapper; no printf/varargs/FP */

/* Serialize an int as 8 lowercase hex digits, low-risk under the very MesCC we
 * are indicting: only a constant >>4, a mask, and a table index -- none of the
 * OR-chain-before-conditional pattern that bug #11 is about.  main() self-tests
 * it on a known constant (self=0x12345678) before trusting it on f(3), so a
 * miscompiled writer would announce itself instead of lying about f(3). */
void emit_hex(char *tag, int v){
  char h[8];
  char *d = "0123456789abcdef";
  int i = 0;
  int k;
  while (tag[i]) i++;
  write(1, tag, i);
  write(1, "=0x", 3);
  for (k = 7; k >= 0; k--){ h[k] = d[v & 0xf]; v = v >> 4; }
  write(1, h, 8);
  write(1, "\n", 1);
}

int f(int t){
  int r2 = 0x40;
  return 0xEEB80A00 | r2 | ((t & 0xf) != 8 ? 0x100 : 0);
}
int main(){
  int v;
  emit_hex("self", 0x12345678);         /* writer self-test: MUST print 12345678 */
  v = f(3);                             /* correct = 0xEEB80A00 | 0x40 | 0x100 = 0xEEB80B40 */
  emit_hex("f(3)", v);                  /* the ACTUAL returned value, whatever it is */
  if (v == (int)0xEEB80B40) return 0;   /* base preserved  -> a correct compiler */
  if (v == 0x100)           return 2;   /* base dropped, only the ternary 0x100 survives -> the MesCC bug */
  return 3;                             /* some other wrong value */
}
