/* One-variable probe for the ARM `.word` directive-width bug (tcc patch 0009).
   musl-1.1.24's a_crash() emits exactly this inline: the ARM permanently-
   undefined instruction 0xe7f000f0. tccasm.c groups `.word` with `.short`
   (size = 2 -- the x86 convention), so a stock tcc truncates this to two
   bytes; on ARM (and in GNU as) `.word` is a 32-bit datum. Assembled short,
   it left musl's .text 2-byte-misaligned and later branch fixups walked
   corrupted offsets. This file is emitted entirely by tcc's own assembler,
   so a host-gcc-built ARM-target tcc reproduces it with no bootstrap. */
__asm__(".word 0xe7f000f0");
