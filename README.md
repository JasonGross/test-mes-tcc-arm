# Three arm bugs block the MesCC armv7l bootstrap of janneke's tcc

**Summary.** janneke's mes fork of tcc (`tcc-0.9.26-1147-gee75a10c`, the
tarball [live-bootstrap](https://github.com/fosslinux/live-bootstrap) pins)
ships a complete ARM backend, but it has never been driven through MesCC for
a 32-bit-ARM (`TCC_ARM_EABI`) `BOOTSTRAP` build. Three source bugs stop it —
one at MesCC parse time, one at the hex2 link, and one in the ARM code tcc
emits — and once all three are fixed the whole `tcc.c` translation unit
compiles under MesCC to a working armv7l `tcc`. This repo demonstrates the
three bugs **from source** in CI: the hex0 seed builds stage0-posix, that
builds an armv7l `mes-m2`, and that runs MesCC over tcc's own source under
`qemu-arm`. (The end-to-end job that builds a *self-hosting* `tcc-mes` from
all three fixes is being finalized and will be added shortly — see the CI
section below.)

Bugs 1 and 2 are the same class: the fork added `#if !BOOTSTRAP` /
`#if BOOTSTRAP && __arm__` guards for the arm bootstrap path but the guards
are inconsistent — one arm site was missed, and one use is not gated on the
EABI variant its token table requires. Bug 3 is independent: a wrong ARM
instruction encoding that real silicon tolerates but qemu (correctly)
rejects. None of the three reproduces on x86 or riscv64 (different
backends), so the existing live-bootstrap routes never hit them.

## Bug 1 — `arm-gen.c`: brace-assignment `avregs = {0}` (fails MesCC parse)

`AVAIL_REGS_INITIALIZER` is a compound literal for real compilers but a bare
brace list under bootstrap:

```c
#if !BOOTSTRAP
#define AVAIL_REGS_INITIALIZER (struct avail_regs) { { 0, 0, 0}, 0, 0, 0 }
#else
#define AVAIL_REGS_INITIALIZER {0}
#endif
```

`assign_regs` only ever uses it to *initialise* a declaration
(`struct avail_regs avregs = AVAIL_REGS_INITIALIZER;` — legal), but
`gfunc_prolog` **re-assigns** it:

```c
avregs = AVAIL_REGS_INITIALIZER;   /* -> avregs = {0};  under BOOTSTRAP */
```

A brace list can initialise but not assign, so this is invalid C. MesCC's
nyacc parser rejects it at the brace and the compile fails:

```
<stdin>: parse failed at state 367, on input "{"
```

**Fix** (`fix1-arm-gen.patch`): gate the reassignment the same way the fork
already gates the compound literals — use a declaration + struct assignment
under BOOTSTRAP:

```c
#if !BOOTSTRAP
    avregs = AVAIL_REGS_INITIALIZER;
#else
    { struct avail_regs _tmp = AVAIL_REGS_INITIALIZER; avregs = _tmp; }
#endif
```

## Bug 2 — `tccgen.c`: `TOK___memmove` undefined under EABI (fails hex2 link)

For a bootstrap arm struct copy / zero-init, `tccgen.c` selects a
double-underscore mem token:

```c
#if BOOTSTRAP && __arm__
    vpush_global_sym(&func_old_type, TOK___memmove);   /* and TOK___memset */
#else
    vpush_global_sym(&func_old_type, TOK_memmove);
#endif
```

But `tcctok.h` only *defines* those tokens for the non-EABI ABI:

```c
#ifndef TCC_ARM_EABI
     DEF(TOK___memmove, "__memmove")
     DEF(TOK___memset, "__memset")
```

So an EABI build (`__arm__` is defined; `TCC_ARM_EABI` is defined) references
an **undefined** token. MesCC does not diagnose it — it leaks the identifier
as an external symbol into `tcc.s`, and the hex2 link fails:

```
Target label TOK___memmove is not valid
```

**Fix** (`fix2-tccgen.patch`): gate the two uses off EABI too, so an EABI
build falls through to `TOK_memmove` / `TOK_memset`, which `tcctok.h` maps to
`__aeabi_memmove` / `__aeabi_memset`:

```c
#if BOOTSTRAP && __arm__ && !defined (TCC_ARM_EABI)
```

The EABI runtime then needs those `__aeabi_mem*` entry points. Neither the
mes libc nor tcc's `lib/armeabi.c` defines them, so `arm-aeabi-mem.c`
supplies thin wrappers over the mes libc `memmove`/`memset` (note the ARM
EABI `__aeabi_memset(dest, n, c)` argument order, which is exactly what tcc's
`init_putz` already emits for arm).

## Bug 3 — `arm-gen.c`: `CMP` written with a non-zero SBZ field (SIGILL on qemu)

With bugs 1 and 2 fixed, MesCC produces a `tcc-mes` that links and whose
`-version` runs — but anything `tcc-mes` compiles that contains a memory-reading
loop (`while (s[i])` → `strlen`, `puts`, `printf`) faults with **SIGILL** under
qemu. The cause is in `gen_opi`: the comparison operators fall through to the
generic data-processing path, which allocates a scratch register and ORs it
into instruction bits `[15:12]` — but for `CMP` (opcode `0x15`) those bits are
**SBZ** (should-be-zero; `CMP` has no destination register). So `cmp r1, #0`
is emitted as `0xe3511000` instead of `0xe3510000`:

```
stock  cmp r1, #0  = 0xe3511000   <-- scratch reg r1 leaked into SBZ [15:12]
fix3   cmp r1, #0  = 0xe3510000   <-- SBZ = 0, correct
```

Both **disassemble identically** (`objdump` and qemu both print `cmp r1, #0`);
only the bytes differ. Real ARM cores ignore the SBZ field, so the bad encoding
runs fine on hardware — but a strict decoder such as qemu treats the encoding
as UNPREDICTABLE and raises SIGILL. It only bites when the allocated scratch
register isn't `r0`, i.e. any loop whose condition reads memory. This is **not**
a qemu bug and **not** a MesCC artifact: verified on qemu-arm 7.2.22 and
10.0.11 (both fault the bad encoding, both run the fixed one), and a gcc-built
tcc from the same source emits the same `0xe3511000`, so the bug is in tcc's
source.

**Fix** (`fix3-arm-cmp.patch`): skip the `r<<12` OR when `opc == 0x15`:

```c
{ int is_cmp = (opc == 0x15);
  ...
  o(x|(is_cmp?0:(r<<12)));            /* const-operand path */
  ...
  o(opc|(is_cmp?0:(r<<12))|fr); }     /* reg-operand path   */
```

## This repository

`bootstrap.sh` builds everything from source, nothing vendored but the tiny
fix/support files here:

1. `oriansj/stage0-posix` x86 tools from the hex0 seed (M2-Planet cross-emits
   armv7l; the host arch is irrelevant).
2. GNU Mes 0.27.1 (ftp.gnu.org) → an armv7l `mes-m2` via mes's own
   `kaem.arm`, with the two known mes-side arm fixes:
   `arm_defs-additions.M1` (the `{R8}/{R9}/{R10}` register operands current
   M2-Planet needs) and `mes-real-raise.c` (a real `raise()` so a failed
   MesCC compile aborts with a *readable* message instead of a SIGSEGV that
   hides it — which is what makes bug 1's diagnostic visible).
3. nyacc 1.00.2 (MesCC's C parser) and the tcc source tarball (sha256-pinned).

`repro.sh <parse|token|fixed>` then extracts a fresh tcc tree, applies the
fixes for that case, and asserts the outcome. The mes arm MesCC libc archives
(needed to link `tcc.s`) are built on demand from mes's own
`build-aux/configure-lib.sh` source lists. `bug3.sh` is a standalone A/B for
bug 3 that needs neither the bootstrap nor MesCC.

CI (`.github/workflows/ci.yml`) runs three independent jobs on stock Ubuntu
runners. The first two rebuild the toolchain and run one MesCC compile of the
full `tcc.c` — hours under `qemu-arm`, hence the long per-job timeout:

- **bug1-parse** — stock tarball → MesCC `-S` fails with
  `parse failed at state 367, on input "{"`.
- **bug2-token** — `fix1` only → `-S` succeeds, but the `tcc.s` link fails
  with `Target label TOK___memmove is not valid`.
- **bug3-cmp** — a fast, self-contained encoding A/B (no bootstrap, minutes
  not hours): build two tcc oracles from the pinned tarball with host gcc
  (stock and `+fix3`), have each compile the `while (s[i])` loop, show the
  emitted `cmp` differs only in the SBZ nibble (`0xe3511000` vs `0xe3510000`),
  link freestanding ARM ELFs, and run them — the stock encoding SIGILLs, the
  fixed one runs. The job records the runner's `qemu-arm --version`; the
  result does not depend on it.

bug1-parse and bug2-token demonstrate bugs 1 and 2 directly — each stops at
the predicted failure. bug3-cmp isolates bug 3 to the single faulting
instruction and shows the works-on-silicon / faults-on-qemu behavior with a
gcc-built oracle, independent of MesCC, so fix 3's encoding change is verified
on its own.

A fourth, end-to-end job — `fix1` + `fix2` + `fix3` + `arm-aeabi-mem.c` →
MesCC builds a `tcc-mes` that itself compiles a `hello.c` which **runs** under
`qemu-arm` and self-hosts — is being finalized and will be added shortly (the
`fix3` formulation is being reworked so the MesCC-built `tcc-mes` is trustworthy
end-to-end, not merely able to print `-version`). That job also needs three
ABI/runtime prerequisites orthogonal to the tcc bugs: `-D TCC_TARGET_ARM=1`
when compiling `lib/libtcc1.c` (to skip its x86-only CPU block), and two fixes
to mes's `arm-mes-gcc/crt1.c` — a no-prototype `main` declaration under
`__TINYC__` (its bare `main ()` call is otherwise rejected by tcc's strict
argument check), and moving the argc/argv/envp register reload to after
`__init_io()` (a C call clobbers `r0-r3`, so the original order passed `main`
garbage). Both crt1 points are upstreamable — the arm crt1 was never validated
against a strict-arg-check tcc.

Versions: tcc `0.9.26-1147-gee75a10c` (sha256
`6b8cbd0a…b6e819f`); GNU Mes 0.27.1; nyacc 1.00.2; stage0-posix latest
`master`.
