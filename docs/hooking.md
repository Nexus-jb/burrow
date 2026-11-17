# How function hooking works

This page describes Burrow's hooking engine: how a hook is installed and
which rules keep it safe. The code is in `src/hook.c` (choosing and writing
patches), `src/relocate.c` (moving instructions) and `src/memory_*.c`
(platform memory primitives).

## Overview

To hook a function, Burrow overwrites its first instructions with a branch
to the replacement. The overwritten instructions are copied into a
*trampoline*, followed by a branch back to the rest of the function. Calling
the trampoline therefore runs the original function; it is what the
`original` pointer receives.

```
target:      B replacement          trampoline:  <first instruction, moved>
             <rest of the function>              B target + 4
```

## Patches

Burrow picks the smallest patch that is safe, in this order:

| Words | Patch | When |
| ----- | ----- | ---- |
| 1 | `B replacement` | The replacement is within 128 MiB of the target. |
| 1 | `B island` | An *island* (a small absolute jump) can be placed within 128 MiB. |
| 3 | `ADRP x, page; ADD x, x, offset; BR x` | The replacement, or an island, is within 4 GiB. |
| 4 | `LDR x, #8; BR x; .quad replacement` | Always possible if the function is long enough. |

The one-word patch is preferred because it replaces a single instruction
with a single aligned store, and because it moves the fewest instructions.

The multi-word patches use `x17` or `x16` as a scratch register. These are
the intra-procedure-call registers, which a caller cannot expect to survive
a call. If the instructions being replaced use one of them, Burrow uses the
other. If they use both, only the one-word patch is possible.

## When a patch is refused

A hook that cannot be installed safely fails with `BURROW_ERR_UNSUPPORTED`
and leaves the target untouched. A patch of a given size is refused when:

- **The function is shorter than the patch.** If a replaced instruction
  never continues (`B`, `BR`, `RET`, `BRK`...), the words after it may belong
  to another function, or may be where another hooking library's trampoline
  returns to. Nothing may follow such an instruction inside the patch.
- **Code branches into the patch.** Burrow scans the 64 instructions after
  the target for direct branches into the second, third or fourth word. Such
  a branch would land in the middle of the patch.
- **A replaced instruction branches forward into the patch.** A branch back
  to an earlier replaced instruction is redirected into the trampoline; a
  branch forward cannot be.
- **A literal straddles the patch.** A literal that lies wholly inside the
  patch is copied into the trampoline. One that lies partly outside cannot
  be.
- **A replaced instruction is unallocated or a system instruction.**

## Moving instructions

Most instructions are copied unchanged. Those that refer to the program
counter are rewritten for the trampoline's address:

| Instruction | In range of the trampoline | Out of range |
| ----------- | -------------------------- | ------------ |
| `B` | `B` | `MOV x, target; BR x` |
| `BL` | `BL` | `MOV x, target; BLR x` |
| `B.cond`, `CBZ`, `CBNZ`, `TBZ`, `TBNZ` | re-encoded | inverted condition skipping a full jump |
| `ADR` | `ADR` | `MOV xd, address` |
| `ADRP` | `ADRP` | `MOV xd, page` |
| `LDR`, `LDRSW` (literal) | re-encoded | `MOV xt, address; LDR xt, [xt]` |
| `LDR` (literal, SIMD&FP) | re-encoded | `MOV x, address; LDR qt, [x]` |
| `PRFM` (literal) | re-encoded | dropped (it is only a hint) |

`MOV x, value` stands for a `MOVZ` followed by a `MOVK` for each non-zero
16-bit part.

## Hooking a function twice

When a function is hooked again, by Burrow or by another library, its first
words are the previous patch. They are moved like any other instructions:
a `B` is relocated, and the four-word absolute jump that most hooking
libraries write (`LDR Xn, #8; BR Xn; .quad`) is recognized and moved as one
jump. The new hook runs first and reaches the previous one through its
`original` pointer.

## Batches

`burrow_hook_functions` installs a batch of hooks all or nothing. It plans
every hook first, then makes the trampolines executable, sets every
`original` pointer, and only then writes the patches. If writing a patch
fails, the patches already written are restored.

Trampolines are allocated in pages per batch, near their targets when
possible. Once a batch's pages are executable they are never written again,
so a page is never non-executable while another thread may be running a
trampoline in it. Trampoline memory is never freed, because a thread may be
inside a trampoline at any time.

## Writing code on iOS

On iOS a page cannot be writable and executable at once. To patch a function,
Burrow makes its page writable with `VM_PROT_COPY` (the process gets a
private copy of the page), writes the patch, and restores the protection.
The jailbreak is what allows the modified page to run.

While the page is writable it is not executable. Only Burrow's own code runs
in that window, and the protection changes use the Mach trap directly,
without calling into `libsystem_kernel`, so a function that shares a page
with `mach_vm_protect` can still be hooked.

## Objective-C methods

`burrow_hook_message` (in `burrow/objc.h`) hooks a method through the public
Objective-C runtime API, like `MSHookMessageEx` in Substrate. For a class
method, pass the metaclass.

- **The class defines the method.** Its implementation is replaced with
  `method_setImplementation`, and `original` receives the previous one.
- **The class only inherits the method.** Burrow adds the method to the
  class with `class_addMethod`, using the inherited method's type encoding.
  `original` is then a stub that, on every call, looks up the superclass's
  current implementation and jumps to it. A hook added to the superclass
  later is therefore still reached, and calling `original` behaves like a
  message to `super`.

The stubs are built into the library (`src/objc_stubs.S`), 4096 of them,
so hooking a method never generates code at run time. Each stub puts its
number in `x16` and jumps to a common routine that saves `x0` to `x8` and
`q0` to `q7`, asks the runtime for the implementation, restores them and
jumps. Stack arguments are untouched, so methods of any signature work,
including ones that return large structures. If a process uses all 4096,
`original` falls back to the superclass's implementation at the time of the
hook.

## Pointer authentication (arm64e)

On arm64e, function pointers carry a signature in their upper bits. Burrow
strips the signature from the target and replacement it is given, so
signed and unsigned pointers both work, and it signs every code pointer it
hands out (trampolines and Objective-C stubs) the way the compiler signs a
C function pointer: key IA, discriminator 0. Callers can therefore call
`original` like any function pointer. The Objective-C stub routine
authenticates the implementation it gets from the runtime with `braaz`.

Instructions that use pointer authentication, such as `pacibsp` at the
start of compiled functions, are moved like any other instruction. Each
moved instruction runs with the same stack pointer as before, so return
addresses are signed and authenticated with the same modifier.

## Not supported yet
- Removing hooks.
- Suspending other threads while code is patched. Hooks are normally
  installed while a tweak loads, before the process starts other work.

## Testing

`make test` runs these suites:

- `tests/relocation_tests.c` checks decoding, encoding and relocation word by
  word. It runs on any host.
- `tests/hook_tests.c` hooks real functions, written in assembly in
  `tests/targets.S`, and checks the results of the hooked and original
  functions. It runs on arm64 Linux, macOS and iOS, once per mode: one-word
  patches straight to the replacement or through an island, three- and
  four-word patches, and both of those with trampolines more than 4 GiB away.
  If a hook crashes the process, it prints the mode and the test that was
  running.
- On arm64e, `hook-tests` also hooks a function that starts with
  `pacibsp` and ends with `retab`, and passes signed pointers to the engine.
- `tests/objc_tests.c` builds classes at run time and hooks their methods:
  defined and inherited methods, a superclass hooked after its subclass,
  chains, class methods, and methods with structure returns, floating-point
  arguments and stack arguments. It runs on macOS and iOS.

Both suites also run on jailbroken iPhones. CI builds them into a rootless
package, `com.nexusjb.burrow-tests` (or run `make ios-tests-package` with
Xcode, ldid and dpkg installed), once for arm64 and once for arm64e. Install
it, then run `burrow-tests` in a terminal: it runs both sets.

Device results so far:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 (arm64 tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.8 | All suites passed |
| iPhone 14 Pro Max | A16 (arm64 tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.12 | All suites passed, including Objective-C |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.16 | All suites passed for both architectures |
