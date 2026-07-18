/* bug #11, patch 0006's rewrite: lift the inline conditional into its own
 * local so the OR-chain contains no inline conditional at all.  With no
 * conditional to precede, MesCC drops nothing and the base survives.
 *
 * This is the exact transformation patch 0006 applies at tcc's five T2CPR
 * sites (a gcc build is a byte-identical no-op).  Under stock MesCC this shape
 * compiles correctly -> 0xEEB80B40 (exit 0), where orchain-bug.c returns 0x100.
 *
 * main() prints the value it got (f(3)=0x........) via the same raw-write
 * emit_hex as orchain-bug.c, so the CI log shows the fixed value directly.
 */

int write(int fd, char *buf, int n);   /* raw syscall wrapper; no printf/varargs/FP */

/* Identical trustworthy hex writer as orchain-bug.c (self-tested in main). */
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
  int cpr = ((t & 0xf) != 8) ? 0x100 : 0;   /* the conditional, alone in its own local */
  return 0xEEB80A00 | r2 | cpr;             /* plain OR-terms only */
}
int main(){
  int v;
  emit_hex("self", 0x12345678);         /* writer self-test: MUST print 12345678 */
  v = f(3);
  emit_hex("f(3)", v);                  /* the ACTUAL returned value */
  return (v == (int)0xEEB80B40) ? 0 : 1; /* 0 = base preserved (correct) */
}
