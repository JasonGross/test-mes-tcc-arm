#include <stdio.h>

/* Sum 1..n -- exercises integer addition in a loop.  If MesCC's ternary
   miscompile (the reason fix 3 must be if/else, not `is_cmp?0:(r<<12)`)
   were present, every add would emit a 0x00000000 word, so `i` never
   advances and this loop hangs -- it cannot silently return a plausible
   wrong value. */
static int sum_to(int n)
{
  int s = 0;
  int i;
  for (i = 1; i <= n; i = i + 1)
    s = s + i;
  return s;
}

/* strlen via while (s[i]) -- exercises the CMP whose SBZ nibble bug 3 breaks. */
static int slen(const char *s)
{
  int n = 0;
  while (s[n])
    n = n + 1;
  return n;
}

int main(void)
{
  const char *msg = "hello from tcc-armv7l";
  puts(msg);                      /* prints; also drives the libc strlen/CMP path */
  return sum_to(10) + slen(msg);  /* 55 + 21 = 76, encoded in the exit code */
}
