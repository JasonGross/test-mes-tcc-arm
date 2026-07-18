int f7(int a,int b,int c,int d,int e,int f,int g){ return a+b+c+d+e+f+g; }
int g4(int a,int b,int c,int d){ return a+b+c+d; }
int main(void){
  int l1=11, l2=22, l3=33, l4=44;
  int r = f7(1,2,3,4,5,6,7);   /* want 28 */
  int s = g4(9,8,7,6);         /* want 30 */
  if (l1!=11||l2!=22||l3!=33||l4!=44) return 100;  /* locals clobbered by stack-arg bug */
  if (r!=28) return 101;
  if (s!=30) return 102;
  return 0;
}
