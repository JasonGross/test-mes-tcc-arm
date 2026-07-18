#!/bin/sh
# Demonstrate the two arm/EABI bugs in janneke's mes fork of tcc and their
# fixes, entirely from the source built by bootstrap.sh. One argument selects
# which case to prove:
#
#   parse  stock tarball. MesCC -S on tcc.c must FAIL in the parser with
#          "parse failed ... on input {" -- the arm-gen.c gfunc_prolog line
#          `avregs = AVAIL_REGS_INITIALIZER;`, which under -D BOOTSTRAP is the
#          non-declaration brace-assignment `avregs = {0};` (invalid C).
#
#   token  fix1 (arm-gen.c) only. MesCC -S now SUCCEEDS, but the tcc.s link
#          must FAIL at hex2 with "Target label TOK___memmove is not valid":
#          tccgen.c emits TOK___memmove under `#if BOOTSTRAP && __arm__`, yet
#          tcctok.h only DEFs that token `#ifndef TCC_ARM_EABI`, so an EABI
#          build references an undefined token that leaks as a symbol.
#
#   fixed  fix1 + fix2 + fix3 (+ arm-aeabi-mem.c runtime wrappers). tcc.c
#          compiles and links to a working armv7l `tcc-mes`: `tcc-mes -version`
#          prints "tcc version 0.9.26", and tcc-mes compiles hello.c to an arm
#          ELF that RUNS under qemu-arm and prints its message (exit 0). fix3
#          (arm-gen.c CMP-SBZ) is what makes that ELF run: without it the
#          `while(s[i])` loops in the tcc-compiled libc emit a CMP with a
#          non-zero SBZ field (0xe3511000) that qemu faults as SIGILL.
#
# Exit status is non-zero unless the selected expectation holds exactly.
set -eu

MODE="${1:?usage: repro.sh <parse|token|fixed>}"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/work/env"          # S0BIN M NY WORK TCC_PKG QEMU

PREFIX="$WORK/tcc-prefix"
LIBDIR="$PREFIX/lib/mes"
INCDIR="$M/include"
export M1="$S0BIN/M1" HEX2="$S0BIN/hex2" BLOOD_ELF="$S0BIN/blood-elf"
export MES_PREFIX="$M" MES_ARENA=30000000 MES_MAX_ARENA=30000000 MES_STACK=15000000
export GUILE_LOAD_PATH="$M/mes/module:$M/module:$NY"
MESCC() { "$QEMU" "$M/bin/mes-m2" --no-auto-compile -e main "$M/mescc.scm" "$@"; }
run_arm() { "$QEMU" "$@"; }
msg() { printf '\n\033[1m:: %s\033[0m\n' "$*"; }

# ---- fresh tcc tree for this mode; apply fixes ----
TCCDIR="$WORK/tcc-$MODE"
rm -rf "${TCCDIR:?}"
tar -C "$WORK" -xzf "$WORK/$TCC_PKG.tar.gz"
mv "$WORK/$TCC_PKG" "$TCCDIR"
: > "$TCCDIR/config.h"
cd "$TCCDIR"
case "$MODE" in
  parse) msg "mode parse: STOCK tarball, no fixes" ;;
  token) msg "mode token: fix1 (arm-gen.c) only"; patch -p1 < "$HERE/fix1-arm-gen.patch" ;;
  fixed) msg "mode fixed: fix1 + fix2 + fix3"
         patch -p1 < "$HERE/fix1-arm-gen.patch"
         patch -p1 < "$HERE/fix2-tccgen.patch"
         patch -p1 < "$HERE/fix3-arm-cmp.patch" ;;
  *) echo "unknown mode: $MODE"; exit 2 ;;
esac

# ---- the MesCC -S invocation (armv7l EABI+VFP, BOOTSTRAP) ----
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

# ---- build the mes arm MesCC libc archives (needed to LINK tcc.s) ----
# Source lists come from mes's own build-aux/configure-lib.sh (arm/linux/mescc),
# assembled in the layered form mes uses. configure-lib.sh correctly puts
# lib/mes/div.c (the ARM software divide helpers __mesabi_*) in libmescc for
# cpu=arm, which the base ISA needs.
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
  # NB: capture the output name before `shift` -- after shifting, $1 is the
  # first source path, so `>> "$1.c"` would write to the wrong file.
  cat_layer() { _out="$1.c"; shift; : > "$_out"; for f in "$@"; do cat "$f"; done >> "$_out"; }
  A="$M/lib/arm-mes"; mkdir -p "$A"
  cc lib/linux/arm-mes-mescc/crt1.c -o "$A/crt1.o"
  # mescc's linker resolves each `-l NAME` to BOTH libNAME.a (the hex2 object
  # archive) and libNAME.s (the M1-source archive), so build the two in lockstep
  # for every layer -- omitting the .s is "mescc: file not found: .../libNAME.s".
  cat_layer libc-mini $MINI;          cc libc-mini.c
  cp libc-mini.o "$A/libc-mini.a";    cp libc-mini.s "$A/libc-mini.s"
  cat_layer libmescc  $MESCCL;        cc libmescc.c
  cp libmescc.o  "$A/libmescc.a";     cp libmescc.s  "$A/libmescc.s"
  cat_layer libc      $LIBC_LAYER;    cc libc.c
  cat "$A/libc-mini.a" libc.o > "$A/libc.a";   cat "$A/libc-mini.s" libc.s > "$A/libc.s"
  cat_layer libctcc   $LIBCTCC_LAYER; cc libctcc.c
  cat "$A/libc.a" libctcc.o > "$A/libc+tcc.a"; cat "$A/libc.s" libctcc.s > "$A/libc+tcc.s"
  ls -la "$A"
}

# ---- assert helpers ----
die() { echo "UNEXPECTED: $*"; exit 1; }

case "$MODE" in

  parse)
    msg "MesCC -S must fail in the parser on the '{' of avregs = {0}"
    set +e
    compile_S > s.log 2>&1
    rc=$?
    set -e
    echo "--> MesCC -S exit $rc"
    tail -25 s.log
    [ "$rc" -ne 0 ] || die "MesCC -S unexpectedly succeeded on the stock tree"
    grep -q "parse failed" s.log || die "no 'parse failed' in MesCC output"
    # nyacc prints the offending token quoted: `on input "{"`.
    grep -qE 'on input "?\{' s.log || die "parser did not stop on '{' (avregs = {0})"
    echo "PASS: stock tcc.c fails MesCC parse at the brace-assignment (bug 1)"
    ;;

  token)
    msg "build mes arm libc archives (to attempt the tcc.s link)"
    build_mes_libc
    msg "MesCC -S must SUCCEED with fix1 applied"
    compile_S
    test -s "$TCCDIR/tcc.s" || die "tcc.s not produced despite fix1"
    echo "tcc.s: $(wc -c < "$TCCDIR/tcc.s") bytes"
    msg "tcc.s link must fail at hex2 on the undefined TOK___memmove token"
    cd "$TCCDIR"
    set +e
    MESCC -o tcc-mes -L "$M/lib" tcc.s -l c+tcc > link.log 2>&1
    rc=$?
    set -e
    echo "--> MesCC link exit $rc"
    tail -25 link.log
    [ "$rc" -ne 0 ] || die "tcc.s linked despite the undefined TOK___memmove"
    # Both TOK___memmove (struct copy) and TOK___memset (zero-init) leak under
    # EABI; hex2 rejects whichever unresolved label it reaches first.
    grep -qE "Target label TOK___(memmove|memset) is not valid" link.log \
      || die "expected 'Target label TOK___memmove/TOK___memset is not valid'"
    grep -oE "Target label TOK___(memmove|memset) is not valid" link.log | head -1
    echo "PASS: EABI build leaks TOK___mem* token; hex2 rejects the label (bug 2)"
    ;;

  fixed)
    msg "build mes arm libc archives"
    build_mes_libc
    msg "MesCC -S then link tcc.s -> tcc-mes"
    compile_S
    test -s "$TCCDIR/tcc.s" || die "tcc.s not produced"
    cd "$TCCDIR"
    mkdir -p "$LIBDIR/tcc" "$PREFIX/include/mes"
    MESCC -o tcc-mes -L "$M/lib" tcc.s -l c+tcc
    test -x tcc-mes || die "tcc-mes not produced"

    msg "tcc-mes -version under qemu-arm"
    ver=$(run_arm ./tcc-mes -version 2>&1 || true)
    echo "$ver"
    case "$ver" in *"tcc version 0.9.26"*) : ;; *) die "wrong -version: $ver" ;; esac

    msg "stage a tcc-built libc so tcc-mes can link programs"
    cp -r "$M/include/." "$PREFIX/include/mes/"
    # unified mes libc as one TU, compiled by tcc-mes (fast: tcc, not MesCC)
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
    TCC="$TCCDIR/tcc-mes"
    tcc_cc() { run_arm "$TCC" -c -D HAVE_CONFIG_H=1 -I include -I include/linux/arm "$@"; }
    # Two mes-arm-crt1 prerequisites (orthogonal to the tcc bugs; both
    # upstreamable -- arm crt1 was never validated against a strict tcc):
    #  (a) the __TINYC__ _start calls `main ()` bare, which a strict-arg-check
    #      tcc rejects against main's 3-arg prototype -- a no-prototype decl
    #      under __TINYC__ passes and still emits the intended `bl main`;
    #  (b) that _start loaded argc/argv/envp into r0-r2 and THEN called
    #      __init_io() (a C call clobbers r0-r3) before main() with no reload,
    #      so main saw garbage argv -- move the reload to after __init_io().
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
    tcc_cc -o "$LIBDIR/crt1.o" lib/linux/arm-mes-gcc/crt1.c
    # tcc emits crti/crtn into a -static link (the begin/end frames of
    # .init/.fini); mes ships real arm crti.c/crtn.c. Empty stubs would give
    # tcc a bad link, so compile the real ones.
    tcc_cc -o "$LIBDIR/crti.o" lib/linux/arm-mes-gcc/crti.c
    tcc_cc -o "$LIBDIR/crtn.o" lib/linux/arm-mes-gcc/crtn.c
    tcc_cc -o unified-libc.o unified-libc.c
    run_arm "$TCC" -ar cr "$LIBDIR/libc.a" unified-libc.o
    # libtcc1.a: arm helpers + the EABI mem wrappers (arm-aeabi-mem.c).
    # libtcc1.c needs -D TCC_TARGET_ARM=1 to skip its x86-only CPU block.
    tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 -D TCC_TARGET_ARM=1 -o libtcc1.o "$TCCDIR/lib/libtcc1.c"
    tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 -D TCC_TARGET_ARM=1 -o armeabi.o  "$TCCDIR/lib/armeabi.c"
    tcc_cc -D HAVE_LONG_LONG=1 -D HAVE_FLOAT=1 -D TCC_TARGET_ARM=1 -o armflush.o "$TCCDIR/lib/armflush.c"
    tcc_cc -o aeabimem.o "$HERE/arm-aeabi-mem.c"
    run_arm "$TCC" -ar cr "$LIBDIR/tcc/libtcc1.a" libtcc1.o armeabi.o armflush.o aeabimem.o

    msg "tcc-mes compiles hello.c -> armv7l ELF"
    out="$WORK/hello-arm"
    run_arm "$TCC" -static -o "$out" -L "$LIBDIR" -L "$LIBDIR/tcc" \
      -I "$PREFIX/include/mes" -I "$PREFIX/include/mes/linux/arm" "$HERE/hello.c"
    test -x "$out" || die "tcc-mes did not produce a hello binary"
    file "$out"
    case "$(file "$out")" in *"ELF 32-bit"*ARM*) : ;; *) die "hello is not an armv7l ELF" ;; esac

    # Run it. This is the hard proof that fix3 (CMP-SBZ) AND the integer-add
    # codegen are both correct: hello's puts()/slen() run `while (s[i])` loops
    # in the tcc-compiled libc, whose `cmp rN,#0` -- without fix3 -- carries a
    # non-zero SBZ field (0xe3511000) that qemu faults as SIGILL; and sum_to()
    # adds in a loop. The exit code encodes 55+21 = 76, so an add miscompile
    # (which zeroes the loop counters) hangs or mis-exits rather than passing
    # spuriously. Every call in hello.c is <=4 args -- a separate MesCC
    # >4-arg call-cleanup miscompile (tracked upstream) is out of scope here.
    msg "run the tcc-mes-compiled hello under qemu-arm (must print + exit 76)"
    set +e
    got=$(run_arm "$out" 2>&1); rc=$?
    set -e
    echo "hello output: [$got] (exit $rc)"
    [ "$rc" -eq 76 ] || die "hello did not exit 76 (= 55+21; add/CMP miscompile?) -- exit $rc"
    [ "$got" = "hello from tcc-armv7l" ] || die "hello printed the wrong text: [$got]"
    echo "PASS: fix1+fix2+fix3 -> MesCC builds a working tcc-mes (version 0.9.26)"
    echo "      that compiles+links a hello which exercises CMP + integer add"
    echo "      and runs under qemu-arm (exit 76, correct output)."
    ;;
esac
