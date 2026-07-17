#!/bin/bash
# From-seed SELF-HOST FIXPOINT for the MesCC-built armv7l tcc.
#
# Runs after bootstrap.sh (shares the from-hex0 toolchain via work/env). Unlike
# the parse/token/fixed reproducers -- which apply only fix1/2/3 and stop at a
# tcc-mes that compiles+runs hello -- this job carries the FULL patch set and
# proves the headline claim: with the mes patch (mes/0001) plus the complete
# tinycc series (0001-0010), a MesCC-built tcc self-hosts to a byte-identical
# fixpoint on armv7l, from the hex0 seed:
#
#     tcc-mes -> tcc-boot0 -> tcc-boot1 -> tcc-boot2 == tcc-boot3   (under qemu-arm)
#
# The assertion is the PROPERTY: two successive tcc-built generations come out
# byte-identical (the codegen reproduces itself exactly). We do NOT hard-pin an
# absolute sha: the boot rounds bake absolute build paths into every binary
# (-D CONFIG_TCCDIR/CONFIG_TCC_LIBPATHS/... are string constants, plus -g debug
# paths), so the fixpoint sha is specific to the build tree's location -- it is
# reproducible across re-runs on the same layout, but differs between machines.
# We log the full sha set and compare boot2 to the local-lineage reference for
# information only.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/work/env"          # S0BIN M NY WORK TCC_PKG QEMU

msg() { printf '\n\033[1m:: %s\033[0m\n' "$*"; }
die() { echo "UNEXPECTED: $*"; exit 1; }

# Local-lineage boot2==boot3 reference (arm-pivot-tcc.sh, run14, 0001-0010 +
# mes/0001). NOT expected to match here -- see the baked-in-path note above.
EXPECT_LOCAL=f87f43d4cc2d80d8bf35811c8bf87ce11d047e0d5adf8aa9eb0170e34d9a82b0

PREFIX="$WORK/tcc-prefix"
LIBDIR="$PREFIX/lib/mes"
INCDIR="$M/include"
BINDIR="$WORK/tcc-bin"; mkdir -p "$BINDIR"
export M1="$S0BIN/M1" HEX2="$S0BIN/hex2" BLOOD_ELF="$S0BIN/blood-elf"
# 50M arena (MAX==ARENA disables gc growth, whose realloc overflows qemu-arm's
# 32-bit guest VA). mes/0001's by-value aggregate copies need >30M; 30M dies
# mid-emit on the fixed-MesCC tcc.c compile.
export MES_PREFIX="$M" MES_ARENA=50000000 MES_MAX_ARENA=50000000 MES_STACK=15000000
export GUILE_LOAD_PATH="$M/mes/module:$M/module:$NY"
MESCC() { "$QEMU" "$M/bin/mes-m2" --no-auto-compile -e main "$M/mescc.scm" "$@"; }
run_arm() { "$QEMU" "$@"; }

OD=arm-linux-gnueabihf-objdump
command -v "$OD" >/dev/null 2>&1 || die "no $OD (need binutils-arm-linux-gnueabihf for the VFP static gate)"

# ---- mes patch (bug#13 struct-copy-init cure): the root of #9/#10/#12 --------
# MesCC interprets module/mescc/compile.scm at runtime (--no-auto-compile), so
# patching the .scm takes effect with no mes-m2 rebuild. Idempotent.
CSCM="$M/module/mescc/compile.scm"
if ! grep -q 'A multi-word aggregate initialised from an expression' "$CSCM"; then
  patch -p1 -d "$M" < "$HERE/patches/mes/0001-mescc-struct-copy-init-by-value.patch" \
    || die "failed to apply mes/0001 to $CSCM"
  msg "applied mes/0001 (bug#13 struct-copy-init cure) to MesCC compile.scm"
else
  msg "mes/0001 already present in MesCC compile.scm"
fi

# ---- fresh tcc tree; apply the full canonical series 0001-0010 --------------
TCCDIR="$WORK/tcc-fixpoint"
rm -rf "${TCCDIR:?}"
tar -C "$WORK" -xzf "$WORK/$TCC_PKG.tar.gz"
mv "$WORK/$TCC_PKG" "$TCCDIR"
: > "$TCCDIR/config.h"
cd "$TCCDIR"
for p in "$HERE"/patches/tinycc/00*.patch; do
  patch -p1 < "$p" >/dev/null || die "failed to apply $(basename "$p")"
done
msg "applied tinycc patches 0001-0010 ($(ls "$HERE"/patches/tinycc/00*.patch | wc -l) patches)"

# ---- MesCC -S tcc.c -> tcc.s (armv7l EABI+VFP, BOOTSTRAP) --------------------
compile_S() {
  cd "$TCCDIR"
  MESCC -S -o tcc.s \
    -I "$INCDIR" -I "$INCDIR/linux/arm" -I . \
    -D BOOTSTRAP=1 -D HAVE_LONG_LONG=0 \
    -D TCC_TARGET_ARM=1 -D TCC_ARM_EABI=1 -D TCC_ARM_VFP=1 -D inline= \
    -D CONFIG_TCCDIR="\"$LIBDIR/tcc\"" -D CONFIG_SYSROOT="\"/\"" \
    -D CONFIG_TCC_CRTPREFIX="\"$LIBDIR\"" -D CONFIG_TCC_ELFINTERP="\"/mes/loader\"" \
    -D CONFIG_TCC_SYSINCLUDEPATHS="\"$PREFIX/include/mes\"" -D TCC_LIBGCC="\"$LIBDIR/libc.a\"" \
    -D CONFIG_TCC_LIBTCC1_MES=0 -D CONFIG_TCCBOOT=1 -D CONFIG_TCC_STATIC=1 \
    -D CONFIG_USE_LIBGCC=1 -D TCC_VERSION="\"0.9.26\"" -D ONE_SOURCE=1 \
    tcc.c
}

# ---- mes arm MesCC libc archives (needed to LINK tcc.s -> tcc-mes) ----------
build_mes_libc() {
  cd "$M"
  cat > config.sh <<'CFG'
mes_libc=mes
mes_kernel=linux
mes_cpu=arm
compiler=mescc
CFG
  V=0 . ./build-aux/configure-lib.sh
  layer() { python3 -c '
import sys
full=sys.argv[1].split(); base=set(sys.argv[2].split())
seen=set(); out=[]
for f in full:
    if f and f not in base and f not in seen: seen.add(f); out.append(f)
print("\n".join(out))' "$1" "$2"; }
  MINI=$(printf '%s' "$libc_mini_SOURCES" | tr -s ' \n' '\n\n' | sed '/^$/d')
  MESCCL=$(printf '%s' "$libmescc_SOURCES" | tr -s ' \n' '\n\n' | sed '/^$/d')
  LIBC_LAYER=$(layer "$libc_SOURCES" "$libc_mini_SOURCES")
  LIBCTCC_LAYER=$(layer "$libc_tcc_SOURCES" "$libc_SOURCES")
  cc() { MESCC -D HAVE_CONFIG_H=1 -I include -I include/linux/arm -c "$@"; }
  cat_layer() { _out="$1.c"; shift; : > "$_out"; for f in "$@"; do cat "$f"; done >> "$_out"; }
  A="$M/lib/arm-mes"; mkdir -p "$A"
  cc lib/linux/arm-mes-mescc/crt1.c -o "$A/crt1.o"
  cat_layer libc-mini $MINI;          cc libc-mini.c
  cp libc-mini.o "$A/libc-mini.a";    cp libc-mini.s "$A/libc-mini.s"
  cat_layer libmescc  $MESCCL;        cc libmescc.c
  cp libmescc.o  "$A/libmescc.a";     cp libmescc.s  "$A/libmescc.s"
  cat_layer libc      $LIBC_LAYER;    cc libc.c
  cat "$A/libc-mini.a" libc.o > "$A/libc.a";   cat "$A/libc-mini.s" libc.s > "$A/libc.s"
  cat_layer libctcc   $LIBCTCC_LAYER; cc libctcc.c
  cat "$A/libc.a" libctcc.o > "$A/libc+tcc.a"; cat "$A/libc.s" libctcc.s > "$A/libc+tcc.s"
}

# ---- the tcc-built mes libc, recompiled by a given tcc (per boot round) ------
# Prepared once: staged headers, the unified libc TU, and the arm crt1 fixups.
prepare_libc_sources() {
  mkdir -p "$LIBDIR/tcc" "$PREFIX/include/mes"
  cp -r "$M/include/." "$PREFIX/include/mes/"
  cd "$M"
  cat > config.sh <<'CFG'
mes_libc=mes
mes_kernel=linux
mes_cpu=arm
compiler=gcc
CFG
  V=0 . ./build-aux/configure-lib.sh
  : > unified-libc.c
  for f in $libc_gnu_SOURCES; do cat "$M/$f"; done >> unified-libc.c
  # Two arm-crt1 fixups (orthogonal to the tcc bugs; both upstreamable):
  #  (a) __TINYC__ _start calls `main ()` bare, which a strict-arg-check tcc
  #      rejects against main's 3-arg prototype -- a no-prototype decl under
  #      __TINYC__ passes and still emits `bl main`;
  #  (b) _start loaded argc/argv/envp into r0-r2 then called __init_io() (which
  #      clobbers r0-r3) before main() with no reload -- move the reload after.
  python3 - lib/linux/arm-mes-gcc/crt1.c <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
old_decl='#include <mes/lib-mini.h>\nint main (int argc, char *argv[], char *envp[]);'
new_decl=('#include <mes/lib-mini.h>\n#if !__TINYC__\n'
          'int main (int argc, char *argv[], char *envp[]);\n#else\n'
          'int main ();\n#endif')
if old_decl in s: s=s.replace(old_decl,new_decl,1)
elif '#if !__TINYC__' not in s: sys.exit("crt1.c: main decl pattern not found")
old_start=('  // setup argc, argv, envp parameters in registers\n'
           '  __asm__ (".int 0xe59d0000\\n"); //ldr   r0, [sp]\n'
           '  __asm__ (".int 0xe59d1004\\n"); //ldr   r1, [sp, #4]\n'
           '  __asm__ (".int 0xe59d2008\\n"); //ldr   r2, [sp, #8]\n'
           '  __init_io ();\n  main ();')
new_start=('  __init_io ();\n'
           '  // reload argc/argv/envp AFTER __init_io() (a C call clobbers r0-r3)\n'
           '  __asm__ (".int 0xe59d0000\\n"); //ldr   r0, [sp]\n'
           '  __asm__ (".int 0xe59d1004\\n"); //ldr   r1, [sp, #4]\n'
           '  __asm__ (".int 0xe59d2008\\n"); //ldr   r2, [sp, #8]\n'
           '  main ();')
if old_start in s: s=s.replace(old_start,new_start,1)
elif '__init_io ();\n  // reload' not in s: sys.exit("crt1.c: _start reload pattern not found")
open(f,'w').write(s)
PY
}
libc_with() { # $1 = tcc binary
  local T="$1"; cd "$M"
  local ARMT="-D TCC_TARGET_ARM=1 -D TCC_ARM_EABI=1 -D TCC_ARM_VFP=1"
  tcc_cc() { run_arm "$T" -c -D HAVE_CONFIG_H=1 -I include -I include/linux/arm "$@"; }
  tcc_cc -o "$LIBDIR/crt1.o" lib/linux/arm-mes-gcc/crt1.c
  tcc_cc -o "$LIBDIR/crti.o" lib/linux/arm-mes-gcc/crti.c
  tcc_cc -o "$LIBDIR/crtn.o" lib/linux/arm-mes-gcc/crtn.c
  tcc_cc -o unified-libc.o unified-libc.c
  run_arm "$T" -ar cr "$LIBDIR/libc.a" unified-libc.o
  tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 $ARMT -o libtcc1.o "$TCCDIR/lib/libtcc1.c"
  tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 $ARMT -o armeabi.o  "$TCCDIR/lib/armeabi.c"
  tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 $ARMT -o armflush.o "$TCCDIR/lib/armflush.c"
  tcc_cc -o aeabimem.o "$HERE/arm-aeabi-mem.c"
  run_arm "$T" -ar cr "$LIBDIR/tcc/libtcc1.a" libtcc1.o armeabi.o armflush.o aeabimem.o
}

# ---- VFP static gate (bug #11): inspect a fresh tcc's VFP codegen ------------
# A correct tcc compiles the probe to >=5 vcvt + >=1 vadd; a T2CPR-miscompiled
# one collapses those opcodes to bare data words. Compile -c only, never run --
# catches bug #11 before a boot round would SIGSEGV on the first int->double.
vfp_static_gate() { # $1 = tcc binary, $2 = label
  local T="$1" tag="$2" G="$WORK/gate" nv na
  mkdir -p "$G"
  cat > "$G/vfpcast.c" <<'EOF'
double cvt_i2d(int x){ return x; }
double cvt_u2d(unsigned x){ return x; }
int    cvt_d2i(double x){ return (int)x; }
float  cvt_d2f(double x){ return (float)x; }
double cvt_f2d(float x){ return x; }
double add_dd(double a,double b){ return a+b; }
EOF
  run_arm "$T" -c -o "$G/vfpcast.o" "$G/vfpcast.c" 2>/dev/null \
    || die "vfp gate ($tag) DIED (infrastructure): tcc failed to compile vfpcast.c"
  nv=$("$OD" -d "$G/vfpcast.o" 2>/dev/null | grep -ciE '\bvcvt' || true)
  na=$("$OD" -d "$G/vfpcast.o" 2>/dev/null | grep -ciE '\bvadd' || true)
  [ "$nv" -ge 5 ] && [ "$na" -ge 1 ] \
    || die "vfp gate ($tag) FAILED (bug#11): vcvt=$nv (want >=5) vadd=$na (want >=1); VFP opcodes collapsed to data words"
  msg "vfp static gate ($tag): PASS (vcvt=$nv vadd=$na — no T2CPR miscompile)"
}

# ---- runtime gate: the permanent MesCC-miscompile regression suite ----------
gate() { # $1 = tcc binary, $2 = label
  local T="$1" tag="$2" G="$WORK/gate" t rc exp
  mkdir -p "$G"
  cat > "$G/argbug2.c" <<'EOF'
int f7(int a,int b,int c,int d,int e,int f,int g){ return a+b+c+d+e+f+g; }
int g4(int a,int b,int c,int d){ return a+b+c+d; }
int main(void){
  int l1=11, l2=22, l3=33, l4=44;
  int r = f7(1,2,3,4,5,6,7);
  int s = g4(9,8,7,6);
  if (l1!=11||l2!=22||l3!=33||l4!=44) return 100;   /* stacked-arg cleanup clobber (bug #9) */
  if (r!=28) return 101;
  if (s!=30) return 102;
  return 0;
}
EOF
  cat > "$G/structarg.c" <<'EOF'
typedef struct { int a, b; } pair;
int consume(pair p){ return p.a*100 + p.b; }
typedef struct { int a, b, c; } trip;
int consume3(trip t){ return t.a*10000 + t.b*100 + t.c; }
int main(){
  pair p; p.a=3; p.b=4;
  if (consume(p) != 304) return 1;                  /* struct-by-value word dropped (bug #10) */
  trip t; t.a=1; t.b=2; t.c=5;
  if (consume3(t) != 10205) return 2;
  return 0;
}
EOF
  cat > "$G/modtest2.c" <<'EOF'
int main(){
  volatile int a,b; int rc=0;
  a=0;  b=512; if (a%b != 0)  rc|=1;
  a=5;  b=512; if (a%b != 5)  rc|=4;
  a=512;b=512; if (a%b != 0)  rc|=8;
  { volatile unsigned u=5,v=512; if (u%v != 5) rc|=32; } /* __aeabi_idivmod by-value {q,r} (bug #10) */
  a=1000;b=7; if (a%b != 6) rc|=64;
  return rc;
}
EOF
  for t in argbug2 structarg modtest2; do
    run_arm "$T" -static -o "$G/$t" -L "$LIBDIR" -L "$LIBDIR/tcc" \
      -I "$PREFIX/include/mes" -I "$PREFIX/include/mes/linux/arm" "$G/$t.c" \
      || die "gate ($tag) DIED (infrastructure): $t failed to compile/link"
    set +e; run_arm "$G/$t"; rc=$?; set -e
    exp=0
    [ "$rc" -eq "$exp" ] || die "gate ($tag) FAILED (MesCC-miscompile regression): $t exited rc=$rc (want $exp)"
    msg "gate ($tag): $t rc=$rc OK"
  done
  msg "gate ($tag): PASS (>4-arg cleanup #9, 2/3-word struct-by-value #10, modulo)"
}

# ---- hello proof: the tcc under test is a working compiler+linker ------------
hello_proof() { # $1 = tcc binary, $2 = label
  local T="$1" tag="$2" out="$WORK/hello-arm-$2" got rc
  run_arm "$T" -static -o "$out" -L "$LIBDIR" -L "$LIBDIR/tcc" -I "$PREFIX/include/mes" \
    -I "$PREFIX/include/mes/linux/arm" "$HERE/hello.c"
  # hello.c EXITS 76 BY DESIGN (sum_to(10)=55 + slen=21) -- the exit code is the
  # spurious-pass proof (an integer-add or CMP miscompile cannot land on 76). Do
  # NOT read that nonzero exit as a run failure: capture it (set +e, as gate()
  # does) and assert it is 76. Printing got/rc keeps a real failure diagnosable.
  set +e; got=$(run_arm "$out" 2>&1); rc=$?; set -e
  [ "$rc" -eq 76 ] || die "hello ($tag) did not exit 76 (=55+21; add/CMP miscompile?) -- exit $rc, output: [$got]"
  [ "$got" = "hello from tcc-armv7l" ] || die "hello ($tag) wrong output: [$got]"
  msg "hello proof ($tag): ran, printed \"$got\", exit 76 (55+21)"
}

# ---- a boot generation: tcc(prev) compiles tcc.c -> next; regate; rebuild libc
boot_round() { # $1 prev, $2 out
  msg "boot: $1 compiles tcc.c -> $2"
  cd "$TCCDIR"
  run_arm "$BINDIR/$1" -g -static -o "$2" \
    -D BOOTSTRAP=1 -D HAVE_FLOAT=1 -D HAVE_BITFIELD=1 -D HAVE_LONG_LONG=1 -D HAVE_SETJMP=1 \
    -D TCC_TARGET_ARM=1 -D TCC_ARM_EABI=1 -D TCC_ARM_VFP=1 -I . -I "$PREFIX/include/mes" \
    -D CONFIG_TCCDIR="\"$LIBDIR/tcc\"" -D CONFIG_TCC_CRTPREFIX="\"$LIBDIR\"" \
    -D CONFIG_TCC_ELFINTERP="\"/mes/loader\"" -D CONFIG_TCC_LIBPATHS="\"$LIBDIR:$LIBDIR/tcc\"" \
    -D CONFIG_TCC_SYSINCLUDEPATHS="\"$PREFIX/include/mes\"" -D TCC_LIBGCC="\"$LIBDIR/libc.a\"" \
    -D TCC_LIBTCC1="\"libtcc1.a\"" -D CONFIG_TCCBOOT=1 -D CONFIG_TCC_STATIC=1 \
    -D CONFIG_USE_LIBGCC=1 -D TCC_VERSION="\"0.9.26\"" -D ONE_SOURCE=1 -L . -L "$LIBDIR" tcc.c
  cp "$2" "$BINDIR/"; chmod 755 "$BINDIR/$2"
  run_arm "$BINDIR/$2" -version | grep -q '0.9.26' || die "boot $2 -version wrong"
  vfp_static_gate "$BINDIR/$2" "$2"
  libc_with "$BINDIR/$2"
}

# ===== drive it =============================================================
# Progress heartbeat: one line every 5 min so a slow run is distinguishable
# from a wedged one in the CI log. The MesCC -S compile below is a single
# ~150-min qemu process that otherwise emits nothing; the boot rounds are
# shorter but still minutes each under emulation.
HEARTBEAT_T0=$(date +%s)
( while :; do sleep 300; echo "[heartbeat] $(( ($(date +%s) - HEARTBEAT_T0) / 60 )) min elapsed — still running"; done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true' EXIT

msg "step 1: MesCC -S tcc.c (this is the ~150-min compile) then link tcc-mes"
build_mes_libc
compile_S
test -s "$TCCDIR/tcc.s" || die "tcc.s not produced"
cd "$TCCDIR"
mkdir -p "$LIBDIR/tcc" "$PREFIX/include/mes"
MESCC -o "$BINDIR/tcc-mes" -L "$M/lib" tcc.s -l c+tcc
test -x "$BINDIR/tcc-mes" || die "tcc-mes not produced"
ver=$(run_arm "$BINDIR/tcc-mes" -version 2>&1 || true)
case "$ver" in *"tcc version 0.9.26"*) : ;; *) die "tcc-mes wrong -version: $ver" ;; esac
msg "tcc-mes built ($ver)"

msg "step 2: gate tcc-mes before trusting it to self-host"
vfp_static_gate "$BINDIR/tcc-mes" tcc-mes
prepare_libc_sources
libc_with "$BINDIR/tcc-mes"
hello_proof "$BINDIR/tcc-mes" tcc-mes
gate "$BINDIR/tcc-mes" tcc-mes

msg "step 3: self-host boot rounds until a byte-identical fixpoint"
boot_round tcc-mes tcc-boot0
FIXMAX=6
prev=tcc-boot0; n=1; converged=
while [ "$n" -le "$FIXMAX" ]; do
  cur="tcc-boot$n"
  boot_round "$prev" "$cur"
  if cmp -s "$BINDIR/$prev" "$BINDIR/$cur"; then
    converged="$prev == $cur (converged at generation $n)"; break
  fi
  msg "self-host: $prev != $cur — not yet converged, extending (gen $n/$FIXMAX)"
  prev="$cur"; n=$((n+1))
done

msg "self-host sha set:"; (cd "$BINDIR" && sha256sum tcc-mes $(ls -v tcc-boot? 2>/dev/null))
[ -n "$converged" ] || die "self-host FIXPOINT FAILED: no two successive generations identical within $FIXMAX rounds"
msg "self-host FIXPOINT: $converged byte-identical"

# Informational: compare boot2 to the local-lineage reference. A DIFFERENCE is
# expected and benign -- the boot binaries bake in this build tree's absolute
# paths (CONFIG_TCCDIR/CONFIG_TCC_LIBPATHS/... and -g), so the fixpoint sha is
# location-specific. The PROPERTY (asserted above) is what proves self-host.
if [ -f "$BINDIR/tcc-boot2" ]; then
  got=$(sha256sum "$BINDIR/tcc-boot2" | cut -d' ' -f1)
  if [ "$got" = "$EXPECT_LOCAL" ]; then
    msg "boot2 == local-lineage reference $EXPECT_LOCAL (identical build layout)"
  else
    msg "boot2 = $got (differs from local reference $EXPECT_LOCAL — expected: baked-in build paths differ; the fixpoint PROPERTY holds regardless)"
  fi
fi
echo
echo "PASS: from the hex0 seed, mes/0001 + tinycc 0001-0010 -> a MesCC-built tcc"
echo "      that self-hosts to a byte-identical fixpoint on armv7l."
