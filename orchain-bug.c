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
 */
int f(int t){
  int r2 = 0x40;
  return 0xEEB80A00 | r2 | ((t & 0xf) != 8 ? 0x100 : 0);
}
int main(){
  int v = f(3);                         /* correct = 0xEEB80A00 | 0x40 | 0x100 = 0xEEB80B40 */
  if (v == (int)0xEEB80B40) return 0;   /* base preserved  -> a correct compiler */
  if (v == 0x100)           return 2;   /* base dropped, only the ternary 0x100 survives -> the MesCC bug */
  return 3;                             /* some other wrong value */
}
