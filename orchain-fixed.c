/* bug #11, patch 0006's rewrite: lift the inline conditional into its own
 * local so the OR-chain contains no inline conditional at all.  With no
 * conditional to precede, MesCC drops nothing and the base survives.
 *
 * This is the exact transformation patch 0006 applies at tcc's five T2CPR
 * sites (a gcc build is a byte-identical no-op).  Under stock MesCC this shape
 * compiles correctly -> 0xEEB80B40 (exit 0), where orchain-bug.c returns 0x100.
 */
int f(int t){
  int r2 = 0x40;
  int cpr = ((t & 0xf) != 8) ? 0x100 : 0;   /* the conditional, alone in its own local */
  return 0xEEB80A00 | r2 | cpr;             /* plain OR-terms only */
}
int main(){
  int v = f(3);
  return (v == (int)0xEEB80B40) ? 0 : 1;    /* 0 = base preserved (correct) */
}
