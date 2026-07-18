#!/bin/sh
# bug #11 demo: the MesCC OR-chain miscompile that tcc patch 0006 (VFP T2CPR)
# works around.
#
# This does NOT claim "tcc fails to build without patch 6" (the self-host
# fixpoint job proves the full stack builds); it demonstrates the underlying
# MesCC miscompile in isolation, on an 8-line reproducer, exactly as the
# minimal bug1/bug2/bug3 demos do.
#
# The miscompile is in the RELEASED mes -- no tcc patch and no mes patch is
# involved -- so this runs the STOCK mes-m2 that bootstrap.sh built (GUILE_LOAD
# points at the unmodified module tree). Three steps make it airtight:
#
#   (A) host gcc compiles orchain-bug.c and it returns 0 -> the C is correct;
#       any miscompile below is MesCC's, not a source bug.
#   (B) STOCK MesCC compiles orchain-bug.c and the ELF returns NON-zero
#       (2 = the base OR-terms were dropped, leaving only the ternary 0x100)
#       -> the miscompile, reproduced and RUN under qemu-arm.
#   (C) STOCK MesCC compiles orchain-fixed.c (patch 0006's rewrite: the
#       conditional lifted into its own local) and the ELF returns 0
#       -> the rewrite dodges the miscompile.
#
# Exit status is non-zero unless (A)=0, (B)!=0 and (C)=0 all hold.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/work/env"          # S0BIN M NY WORK TCC_PKG QEMU

export M1="$S0BIN/M1" HEX2="$S0BIN/hex2" BLOOD_ELF="$S0BIN/blood-elf"
export MES_PREFIX="$M" MES_ARENA=30000000 MES_MAX_ARENA=30000000 MES_STACK=15000000
# STOCK mes: the unmodified bootstrap module tree (no mes/0001, no OR-chain fix
# -- the empirical A/B in data/mescc-bugs/bug11-t2cpr-vfp shows mes/0001 has no
# effect on this bug anyway).
export GUILE_LOAD_PATH="$M/mes/module:$M/module:$NY"
MESCC() { "$QEMU" "$M/bin/mes-m2" --no-auto-compile -e main "$M/mescc.scm" "$@"; }
run_arm() { "$QEMU" "$@"; }
msg() { printf '\n\033[1m:: %s\033[0m\n' "$*"; }
die() { echo "UNEXPECTED: $*"; exit 1; }

# ---- build the mes arm MesCC libc archives (crt1 + exit, needed to LINK a
# runnable ELF). Identical to repro.sh's build_mes_libc. ----
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

# ---- compile a source with the STOCK arm MesCC, link a runnable armv7l ELF,
# run it under qemu-arm, echo the exit code ----
mescc_run() {   # $1 = source, $2 = output name -> sets global RC
  cd "$WORK"
  MESCC -D HAVE_CONFIG_H=1 -I "$M/include" -I "$M/include/linux/arm" \
    -o "$2" -L "$M/lib" "$HERE/$1" -l c+tcc
  test -x "$2" || die "$1: MesCC did not produce an ELF"
  case "$(file "$2")" in *"ELF 32-bit"*ARM*) : ;; *) die "$1: not an armv7l ELF" ;; esac
  set +e; run_arm "./$2" >/dev/null 2>&1; RC=$?; set -e
}

msg "(A) host gcc: orchain-bug.c is correct C (the fault below is MesCC's)"
gcc -O0 -o "$WORK/orchain-gcc" "$HERE/orchain-bug.c"
set +e; "$WORK/orchain-gcc"; grc=$?; set -e
echo "--> host gcc orchain-bug exit $grc"
[ "$grc" -eq 0 ] || die "host gcc did not return 0 on orchain-bug.c (exit $grc) -- source is not correct?"

msg "build the mes arm libc archives (crt1 + exit, to link a runnable ELF)"
build_mes_libc

msg "(B) STOCK MesCC: orchain-bug.c -> the OR-chain miscompile, RUN under qemu-arm"
mescc_run orchain-bug.c orchain-bug
bug_rc=$RC
echo "--> stock-MesCC orchain-bug exit $bug_rc  (0 = correct; 2 = base OR-terms dropped; 3 = other wrong value)"
[ "$bug_rc" -ne 0 ] || die "orchain-bug ran correctly under stock MesCC (exit 0) -- the OR-chain miscompile did not reproduce"
if [ "$bug_rc" -ne 2 ]; then
  echo "NOTE: expected 2 (base dropped to 0x100); got $bug_rc -- still a miscompile (non-zero), but a different residual"
fi

msg "(C) STOCK MesCC: orchain-fixed.c (patch 0006's rewrite) -> correct, RUN under qemu-arm"
mescc_run orchain-fixed.c orchain-fixed
fix_rc=$RC
echo "--> stock-MesCC orchain-fixed exit $fix_rc  (0 = correct)"
[ "$fix_rc" -eq 0 ] || die "orchain-fixed did not run correctly under stock MesCC (exit $fix_rc) -- patch 0006's rewrite should dodge the bug"

echo
echo "PASS: stock MesCC drops the pre-conditional OR-terms (orchain-bug exit $bug_rc),"
echo "      but compiles patch 0006's rewrite correctly (orchain-fixed exit 0)."
echo "      host gcc builds the same orchain-bug.c correctly (exit 0), so the"
echo "      miscompile is MesCC's, not a tcc/source bug. This is the MesCC"
echo "      OR-chain miscompile that tcc patch 0006 (VFP T2CPR) works around."
