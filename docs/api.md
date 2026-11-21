# Burrow for tweak developers

Most tweaks need nothing from this page. Burrow implements the Cydia
Substrate and libhooker functions, so a tweak built with Theos against
`CydiaSubstrate.framework` runs on Burrow without being rebuilt.

Burrow's own functions add two things those interfaces do not have: a
status for every failure, and batches of hooks that are installed all
together or not at all. This page explains how to use them, and what Burrow
does with your tweak: where it loads, and what happens when it crashes.

## Which functions to use

| You want | Use |
| --- | --- |
| A tweak that runs on any engine: Burrow, ElleKit, Substrate | The Substrate functions, linked as usual |
| To know why a hook failed, or to hook several functions at once safely | Burrow's functions, looked up at run time, with Substrate as the fallback |

Burrow's functions are in Burrow's hooking engine. A process has Burrow's
engine when the user has switched to it with `burrowctl engine burrow` (see
[migrating-from-ellekit.md](migrating-from-ellekit.md)). Elsewhere, another
engine is loaded and Burrow's functions are absent. So do not link them:
look them up with `dlsym` when your tweak loads. Your tweak then loads under
any engine, and uses Burrow's functions where they are.

## Using Burrow's functions

Copy `include/burrow/burrow.h`, and `include/burrow/objc.h` for Objective-C,
into your project. They are under the Apache License 2.0. Link nothing new.

```c
#include <dlfcn.h>
#include <os/log.h>
#include <substrate.h>
#include <unistd.h>

#include "burrow/burrow.h"

static int (*original_unlink)(const char *);

static int replacement_unlink(const char *path) {
    os_log(OS_LOG_DEFAULT, "MyTweak: unlink %{public}s", path);
    return original_unlink(path);
}

__attribute__((constructor)) static void start(void) {
    __typeof__(&burrow_hook_function) hook =
        (__typeof__(&burrow_hook_function))dlsym(RTLD_DEFAULT, "burrow_hook_function");
    __typeof__(&burrow_status_string) describe =
        (__typeof__(&burrow_status_string))dlsym(RTLD_DEFAULT, "burrow_status_string");
    if (hook && describe) {
        burrow_status status = hook((void *)unlink, (void *)replacement_unlink, (void **)&original_unlink);
        if (status != BURROW_OK) {
            os_log_error(OS_LOG_DEFAULT, "MyTweak: unlink was not hooked: %{public}s", describe(status));
        }
    } else {
        MSHookFunction((void *)unlink, (void *)replacement_unlink, (void **)&original_unlink);
    }
}
```

`tests/substrate_tests.c` finds and uses the functions this way. It runs on
devices in the `burrow-tests` package.

## Functions

### burrow_hook_functions

```c
burrow_status burrow_hook_functions(const burrow_function_hook *hooks, size_t count, size_t *failed_index);
```

Hooks a batch of functions. Each entry names:

- `target`, the function to hook;
- `replacement`, the function to run instead, with the same signature;
- `original`, optional, where to store a pointer that runs the original.

The batch is installed whole or not at all. When one entry cannot be
hooked, no function is changed, the status says why, and `failed_index`
(when not `NULL`) receives the index of that entry.

- `original` is set before the hook takes effect, so a call that comes in
  between still works.
- A function may be hooked again, by your tweak or another. The newest hook
  runs first and reaches the one before it through its `original`.
- Hooks cannot be removed.

### burrow_hook_function

```c
burrow_status burrow_hook_function(void *target, void *replacement, void **original);
```

The same as a batch of one.

### burrow_hook_message

```c
#include "burrow/objc.h"

burrow_status burrow_hook_message(Class cls, SEL selector, IMP replacement, IMP *original);
```

Replaces the implementation of a method. For a class method, pass the
metaclass, `object_getClass(cls)`.

- When `cls` defines the method, its implementation is replaced, and
  `original` receives the previous one.
- When `cls` only inherits the method, Burrow adds the method to `cls`.
  `original` then calls the superclass's implementation as it is at each
  call, like a message to `super`, so a hook added to the superclass later
  is still reached. This works for up to 4096 such hooks in a process;
  beyond that, `original` is the superclass's implementation at the time of
  the hook.
- When neither `cls` nor its superclasses have the method, the status is
  `BURROW_ERR_NOT_FOUND`.

### burrow_status_string

```c
const char *burrow_status_string(burrow_status status);
```

A short English description of a status, for logs.

### Statuses

| Status | Meaning |
| --- | --- |
| `BURROW_OK` | The hooks are installed. |
| `BURROW_ERR_INVALID_ARGUMENT` | A target or replacement is `NULL`, a target is not aligned to an instruction, or a target appears twice in one batch. |
| `BURROW_ERR_NOT_EXECUTABLE` | A target is not in readable, executable memory. |
| `BURROW_ERR_UNSUPPORTED` | The start of a target cannot be patched safely, for example because the function is shorter than the patch it needs. |
| `BURROW_ERR_NO_MEMORY` | Memory for the trampolines could not be allocated. |
| `BURROW_ERR_PROTECTION` | Code pages could not be made writable or executable. |
| `BURROW_ERR_NOT_FOUND` | The class has no method for the selector. |

Whatever the status, a function Burrow could not hook is left exactly as it
was.

## Pointer authentication

On arm64e, pass function pointers as the compiler gives them, signed or
not: Burrow strips the signature. Every pointer Burrow hands back, such as
`original`, is signed the way the compiler signs a C function pointer, so
you call it like any other.

## Rules for safe hooks

- Hook while your tweak loads, in its constructor. Burrow does not pause
  other threads while it patches code, and at load time no other thread runs
  your targets yet.
- Burrow moves the first instructions of a target into a trampoline,
  adjusting those that depend on where they are. When it cannot move them
  safely, it refuses with `BURROW_ERR_UNSUPPORTED`. It does not patch and
  hope. [hooking.md](hooking.md) explains the patches and when each is
  refused.
- Under Dopamine, dyld's image 0 is not always the main executable. To find
  the main executable, look for it by path rather than by index.

## The Substrate and libhooker functions

| Interface | Functions |
| --- | --- |
| Cydia Substrate | `MSHookFunction`, `MSHookMessageEx`, `MSFindSymbol`, `MSGetImageByName`, `MSCloseImage`, `MSHookMemory`, `MSDebug` |
| libhooker | `LHHookFunctions`, `LHPatchMemory`, `LHOpenImage`, `LHCloseImage`, `LHFindSymbols`, `LHStrError` |
| libblackjack | `LBHookMessage` |

Where they differ from what you may expect:

- `MSHookFunction` returns nothing. When it cannot hook a function, it
  leaves the function untouched, writes the reason to the system log, and
  sets your `original` pointer to the function itself, so calling it still
  works.
- `LHHookFunctions` and `LHPatchMemory` return how many entries succeeded.
  Their `options` are accepted and ignored: Burrow chooses the patch itself.
- `MSFindSymbol` and `LHFindSymbols` take names with the leading
  underscore. They find exported symbols and, through the image's symbol
  table, symbols that are not exported. Addresses come back signed on
  arm64e.
- `libsubstitute`'s functions are not provided. Where Burrow's engine is in
  use, `libsubstitute` stays ElleKit's.

## Where your tweak loads

Burrow's loader reads the filter property list beside your tweak as ElleKit
does:

- `CoreFoundationVersion`, when present, must match;
- then any one of `Bundles`, `Classes` and `Executables` is enough.

A filter with two `CoreFoundationVersion` numbers never loads, as in
ElleKit. A tweak built for arm64e with the ABI from before iOS 14 needs
ElleKit's `OldABI.dylib`, as under ElleKit; without it, Burrow skips the
tweak rather than letting it crash the process. `burrowctl check` lists the
tweaks it would skip. Set `IsTweakManager` beside `Filter` only for a tweak
that decides about other tweaks: it loads before them.

Users turn tweaks off by the name of the library without `.dylib`, in every
process or in one. Keep your tweak's file name stable between versions.
[loader.md](loader.md) has the details.

## When your tweak crashes

While the loader opens your tweak, it names the thread
`Burrow: loading <tweak>`, so a crash in your constructor, or in dyld before
any of your code runs, still names your tweak.

When a process crashes, Safe Mode reads the crash report and walks the
crashed thread from the crash down. If your tweak is the first one it finds,
within 12 frames of system and jailbreak code, Safe Mode turns your tweak
off in that process only, and records why, with the report. It keeps
running everywhere else. A tweak that only appears further down a backtrace
is not blamed. The user sees the event in `burrowctl events` and in
Codling, and can turn the tweak back on there or with `burrowctl enable`.

The crash log keeps every crash of a process that had tweaks loaded, with
the tweak to blame and the package it came from. `burrowctl crashes` shows
it. [safe-mode.md](safe-mode.md) explains how blame is decided.
