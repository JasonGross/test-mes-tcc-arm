#!/bin/sh
# Bug (tcc patch 0009): the `.word` assembler directive is 32-bit on ARM, but
# tccasm.c groups it with `.short` (size = 2, the x86 convention), silently
# truncating every ARM `.word` to two bytes. Like bug3, this is a bug in what
# tcc *emits* -- it lives in tcc's own assembler (tccasm.c), so a host gcc-built
# ARM-target tcc reproduces it with no mes bootstrap and no MesCC. Unlike bug3
# it is a pure width/truncation defect, observable *statically*: we never run or
# even link the object, we just read back the .text section it produced.
#
# A/B: build two tcc oracles from the pinned tarball (stock, and stock + fix9),
# have each assemble `__asm__(".word 0xe7f000f0")` (musl a_crash's inline), and
# show the emitted .text section:
#
#   stock  (.word == .short, size 2):  .text = 2 bytes  f000        (TRUNCATED)
#   fixed  (.word == 4 on ARM):        .text = 4 bytes  f000f0e7    (0xe7f000f0 LE)
#
# Exit status is non-zero unless both halves hold exactly.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TCC_PKG=tcc-0.9.26-1147-gee75a10c
TCC_URL=https://lilypond.org/janneke/tcc/$TCC_PKG.tar.gz
TCC_SHA=6b8cbd0a5fed0636d4f0f763a603247bc1935e206e1cc5bda6a2818bab6e819f

WORK="$HERE/work-word"; rm -rf "${WORK:?}"; mkdir -p "$WORK"; cd "$WORK"
msg() { printf '\n\033[1m:: %s\033[0m\n' "$*"; }
die() { echo "UNEXPECTED: $*"; exit 1; }

# arm cross binutils give us the assembler-independent readback (objcopy -O
# binary of just .text). The tcc under test is the only thing that assembled the
# .word; objcopy is used purely to extract the bytes tcc wrote.
OBJCOPY=arm-linux-gnueabihf-objcopy
command -v "$OBJCOPY" >/dev/null 2>&1 || die "no $OBJCOPY (need gcc-arm-linux-gnueabihf)"

msg "fetch + verify tcc source ($TCC_PKG)"
curl -fsSL -o "$TCC_PKG.tar.gz" "$TCC_URL"
echo "$TCC_SHA  $TCC_PKG.tar.gz" | sha256sum -c -
tar xzf "$TCC_PKG.tar.gz"
cp -r "$TCC_PKG" src-stock
cp -r "$TCC_PKG" src-fixed
( cd src-fixed && patch -p1 < "$HERE/fix9-arm-word.patch" )
: > src-stock/config.h; : > src-fixed/config.h

# Host gcc builds tcc as an ARM cross-compiler (same recipe as bug3.sh). No
# -DBOOTSTRAP: the .word width is a plain assembler property, independent of the
# bootstrap guards and of MesCC -- that is the point.
build_oracle() {  # <srcdir> <out>
  gcc -O0 -w -o "$2" \
    -DTCC_TARGET_ARM=1 -DTCC_ARM_EABI=1 -DTCC_ARM_VFP=1 -DONE_SOURCE=1 \
    -DTCC_VERSION='"0.9.26"' \
    -DCONFIG_TCCDIR='"/nonexistent"' -DCONFIG_TCC_CRTPREFIX='"/nonexistent"' \
    -DCONFIG_TCC_SYSINCLUDEPATHS='"/nonexistent"' -DCONFIG_TCC_LIBPATHS='"/nonexistent"' \
    -DCONFIG_TCC_ELFINTERP='"/mes/loader"' "$1/tcc.c"
}
msg "build tcc oracles (host gcc, ARM target): stock vs +fix9"
build_oracle src-stock tcc-stock
build_oracle src-fixed tcc-fixed

msg "each oracle assembles __asm__(\".word 0xe7f000f0\") -> object"
./tcc-stock -c -o word-stock.o "$HERE/word.c"
./tcc-fixed -c -o word-fixed.o "$HERE/word.c"

# Read back the raw .text bytes tcc emitted (version-independent: objcopy -O
# binary of only .text, then measure/dump the file).
text_of() {  # <objfile> <outbin>
  "$OBJCOPY" -O binary --only-section=.text "$1" "$2"
}
text_of word-stock.o text-stock.bin
text_of word-fixed.o text-fixed.bin
sz_stock=$(wc -c < text-stock.bin)
sz_fixed=$(wc -c < text-fixed.bin)
hex_stock=$(od -An -tx1 text-stock.bin | tr -d ' \n')
hex_fixed=$(od -An -tx1 text-fixed.bin | tr -d ' \n')

msg "the emitted .text differs only in the .word width"
echo "  stock: .text = $sz_stock bytes ($hex_stock)"
echo "  fixed: .text = $sz_fixed bytes ($hex_fixed)"

# Bug present: stock truncates the 32-bit .word to the low 2 bytes (f000).
[ "$sz_stock" -eq 2 ] || die "stock .text is $sz_stock bytes, expected 2 (the .word==.short truncation)"
[ "$hex_stock" = "f000" ] || die "stock .text bytes are $hex_stock, expected f000 (low 16 bits of 0xe7f000f0)"
# Bug fixed: the full 32-bit datum survives (f0 00 f0 e7 = 0xe7f000f0 little-endian).
[ "$sz_fixed" -eq 4 ] || die "fixed .text is $sz_fixed bytes, expected 4 (a 32-bit .word)"
[ "$hex_fixed" = "f000f0e7" ] || die "fixed .text bytes are $hex_fixed, expected f000f0e7 (0xe7f000f0 LE)"

echo
echo "PASS: stock tcc groups .word with .short and truncates 0xe7f000f0 to 2"
echo "      bytes (f000); fix9 makes .word a 32-bit datum, emitting the full"
echo "      f000f0e7. Purely static -- no run, no link -- so it isolates the"
echo "      assembler directive from any codegen or emulation behaviour."
