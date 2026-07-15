# Two arm/EABI bugs block the MesCC armv7l bootstrap of janneke's tcc

**Summary.** janneke's mes fork of tcc (`tcc-0.9.26-1147-gee75a10c`, the
tarball [live-bootstrap](https://github.com/fosslinux/live-bootstrap) pins)
ships a complete ARM backend, but it has never been driven through MesCC for
a 32-bit-ARM (`TCC_ARM_EABI`) `BOOTSTRAP` build. Two small source bugs stop
it — one at MesCC parse time, one at the hex2 link — and once both are
fixed the whole `tcc.c` translation unit compiles under MesCC to a working
armv7l `tcc`. This repo proves all of that **from source** in CI: the hex0
seed builds stage0-posix, that builds an armv7l `mes-m2`, and that runs
MesCC over tcc's own source under `qemu-arm`.

Both bugs are the *same class*: the fork added `#if !BOOTSTRAP` /
`#if BOOTSTRAP && __arm__` guards for the arm bootstrap path but the guards
are inconsistent — one arm site was missed, and one use is not gated on the
EABI variant its token table requires. Neither reproduces on x86 or riscv64
(different backends), so the existing live-bootstrap routes never hit them.

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
nyacc parser rejects it and the whole compile dies before emitting anything:

```
mescc: ...
parse failed at state 367, on input {
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
`build-aux/configure-lib.sh` source lists.

CI (`.github/workflows/ci.yml`) runs three independent jobs on stock Ubuntu
runners with `qemu-user-static`. Each rebuilds the toolchain and runs one
MesCC compile of the full `tcc.c` — hours under `qemu-arm`, hence the long
per-job timeout:

- **bug1-parse** — stock tarball → MesCC `-S` fails with
  `parse failed ... on input {`.
- **bug2-token** — `fix1` only → `-S` succeeds, but the `tcc.s` link fails
  with `Target label TOK___memmove is not valid`.
- **fixed** — `fix1` + `fix2` + `arm-aeabi-mem.c` → `tcc.s` links to a
  working `tcc-mes`; `qemu-arm ./tcc-mes -version` prints `tcc version
  0.9.26`, and `tcc-mes` then compiles `hello.c` to an armv7l ELF:

```console
$ qemu-arm ./tcc-mes -version
tcc version 0.9.26 (ARM Linux)
$ qemu-arm ./tcc-mes -static -o hello hello.c
$ file hello
hello: ELF 32-bit LSB executable, ARM, EABI4 version 1 (SYSV), statically linked
```

That both fixes hold is proven directly: with them, MesCC compiles the whole
`tcc.c` and links it into a `tcc-mes` that *runs* (its `-version` executes),
and that `tcc-mes` in turn compiles and links C source into an armv7l ELF.

**Runtime caveat (a separate, still-open bug).** *Running* a tcc-mes-compiled
ELF that calls into the separately-linked libc currently faults under
`qemu-arm` — the fault is a valid ARM instruction with the CPU in ARM state
(not a Thumb/interworking problem), only on cross-object calls; intra-TU
calls and `tcc-mes -version` are fine. This is a third bug in tcc's arm
codegen, **present in the pristine tarball** (`arm-link.c` is unchanged) and
independent of the two bugs here; it is the frontier of the separate
"tcc-boot on arm" (milestone-3) work. The `fixed` job therefore runs the
hello ELF and **reports** the outcome without failing on it; set
`RUN_HELLO_MUST_PASS=1` to hard-assert it once that bug is fixed.

The `fixed` job also applies two ABI-runtime prerequisites orthogonal to the
two tcc bugs: `-D TCC_TARGET_ARM=1` when compiling `lib/libtcc1.c` (to skip
its x86-only CPU block), and a no-prototype `main` declaration under
`__TINYC__` in mes's `arm-mes-gcc/crt1.c` (its bare `main ()` call is
otherwise rejected by tcc's strict argument check).

Versions: tcc `0.9.26-1147-gee75a10c` (sha256
`6b8cbd0a…b6e819f`); GNU Mes 0.27.1; nyacc 1.00.2; stage0-posix latest
`master`.
