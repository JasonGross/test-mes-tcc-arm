#!/bin/sh
# Bug 3 (arm-gen.c CMP-SBZ encoding) as a fast, self-contained A/B -- it needs
# neither the mes bootstrap nor MesCC, because the bug is in the code tcc
# *emits*, and a host gcc-built tcc from the same source emits the same bad
# instruction. So we build two tcc oracles from the pinned tarball (stock, and
# stock + fix3), have each compile a one-line `while (s[i])` loop, and show:
#
#   * the encoding differs in exactly the CMP SBZ nibble:
#       stock  cmp r1, #0  = 0xe3511000   (scratch reg r1 leaks into bits 15-12)
#       fixed  cmp r1, #0  = 0xe3510000   (SBZ = 0, correct)
#   * both disassemble identically ("cmp r1, #0") -- the bytes are what differ;
#   * run under qemu-arm: the stock encoding faults SIGILL (real silicon would
#     ignore the SBZ field and run it), the fixed encoding runs and exits 10.
#
# The `slen` object under test is emitted entirely by tcc; the cross gcc is
# used only to assemble the tiny freestanding driver and to disassemble.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TCC_PKG=tcc-0.9.26-1147-gee75a10c
TCC_URL=https://lilypond.org/janneke/tcc/$TCC_PKG.tar.gz
TCC_SHA=6b8cbd0a5fed0636d4f0f763a603247bc1935e206e1cc5bda6a2818bab6e819f

WORK="$HERE/work-bug3"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
msg() { printf '\n\033[1m:: %s\033[0m\n' "$*"; }
die() { echo "UNEXPECTED: $*"; exit 1; }
QEMU=$(command -v qemu-arm-static || command -v qemu-arm) || die "no qemu-arm"

msg "record the qemu-arm the runner provides (claims are version-independent)"
"$QEMU" --version | head -1 || true

msg "fetch + verify tcc source ($TCC_PKG)"
curl -fsSL -o "$TCC_PKG.tar.gz" "$TCC_URL"
echo "$TCC_SHA  $TCC_PKG.tar.gz" | sha256sum -c -
tar xzf "$TCC_PKG.tar.gz"
cp -r "$TCC_PKG" src-unfixed
cp -r "$TCC_PKG" src-fixed
( cd src-fixed && patch -p1 < "$HERE/fix3-arm-cmp.patch" )
: > src-unfixed/config.h; : > src-fixed/config.h

# Host gcc builds tcc as an ARM cross-compiler. No -DBOOTSTRAP: bug 3 is a plain
# codegen bug, present regardless of the bootstrap guards (that is the point --
# it is not a MesCC artifact).
build_oracle() {  # <srcdir> <out>
  gcc -O0 -w -o "$2" \
    -DTCC_TARGET_ARM=1 -DTCC_ARM_EABI=1 -DTCC_ARM_VFP=1 -DONE_SOURCE=1 \
    -DTCC_VERSION='"0.9.26"' \
    -DCONFIG_TCCDIR='"/nonexistent"' -DCONFIG_TCC_CRTPREFIX='"/nonexistent"' \
    -DCONFIG_TCC_SYSINCLUDEPATHS='"/nonexistent"' -DCONFIG_TCC_LIBPATHS='"/nonexistent"' \
    -DCONFIG_TCC_ELFINTERP='"/mes/loader"' "$1/tcc.c"
}
msg "build tcc oracles (host gcc, ARM target): stock vs +fix3"
build_oracle src-unfixed tcc-unfixed
build_oracle src-fixed   tcc-fixed

msg "each oracle compiles the while(s[i]) loop"
./tcc-unfixed -c -o slen-unfixed.o "$HERE/sigill_loop.c"
./tcc-fixed   -c -o slen-fixed.o   "$HERE/sigill_loop.c"

msg "the emitted CMP differs only in the SBZ nibble"
U=$(arm-linux-gnueabihf-objdump -d slen-unfixed.o | grep -iE '\bcmp\b' | head -1)
F=$(arm-linux-gnueabihf-objdump -d slen-fixed.o   | grep -iE '\bcmp\b' | head -1)
echo "  stock: $U"
echo "  fixed: $F"
echo "$U" | grep -qiE 'e351[1-9a-f]000' || die "stock cmp SBZ nibble is not nonzero (expected e351N000, N!=0)"
echo "$F" | grep -qiE 'e3510000'        || die "fixed cmp is not e3510000"

msg "link freestanding ARM ELFs (driver + slen.o; no libc)"
arm-linux-gnueabihf-gcc -c -marm -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -o driver.o "$HERE/driver.c"
arm-linux-gnueabihf-gcc -marm -nostdlib -static -Wl,--no-warn-mismatch -o sigill-unfixed.arm driver.o slen-unfixed.o
arm-linux-gnueabihf-gcc -marm -nostdlib -static -Wl,--no-warn-mismatch -o sigill-fixed.arm   driver.o slen-fixed.o

msg "run both under qemu-arm"
set +e
"$QEMU" ./sigill-unfixed.arm; ru=$?
"$QEMU" ./sigill-fixed.arm;   rf=$?
set -e
echo "  stock encoding: exit $ru (expect 132 = 128+SIGILL)"
echo "  fixed encoding: exit $rf (expect 10 = slen(\"abcdefghij\"))"
[ "$ru" -eq 132 ] || die "stock encoding did not SIGILL under this qemu (exit $ru)"
[ "$rf" -eq 10 ]  || die "fixed encoding did not run to exit 10 (exit $rf)"

echo
echo "PASS: stock tcc emits a CMP with a non-zero SBZ field (0xe3511000) that"
echo "      qemu rightly faults as UNPREDICTABLE; fix3 emits 0xe3510000, which"
echo "      runs. Real ARM silicon ignores SBZ, so only emulation catches it."
