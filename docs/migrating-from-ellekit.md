# Moving from ElleKit to Burrow

Burrow installs beside ElleKit and changes nothing until you switch. You
switch two parts, one after the other: first the tweak loader, which picks
the tweaks for each process, then the hooking engine, which tweaks call to
hook. After each switch, Burrow watches for 15 minutes, and goes back to
ElleKit by itself if SpringBoard keeps crashing. No tweak needs to be
rebuilt, and you can go back at any time.

The first half of this guide is for users; the second, for tweak
developers.

## Before you start

- A rootless or RootHide jailbreak on iOS 15 or later, on an A12 chip or
  newer. The RootHide package is next to be tried on a device. On RootHide
  every `/var/jb` path below is the same path in its hidden root.
- Install Burrow. It changes nothing yet: its daemon, `burrowd`, keeps the
  crash log.
- Optionally, run `burrowctl check` as root. It reads every tweak and lists:
  - the hooking functions they use, and whether Burrow's engine has each
    one;
  - tweaks built with the old arm64e ABI, which need ElleKit's `OldABI.dylib`
    under Burrow, as under ElleKit;
  - tweaks whose filters give two `CoreFoundationVersion` numbers, which
    neither ElleKit nor Burrow loads.

## 1. Switch the tweak loader

In Codling, tap the gear on the Sources tab, open System, then Burrow, and
tap **Use Burrow's Loader**. Or, as root:

```sh
burrowctl loader burrow
```

Then restart SpringBoard, so that it loads with Burrow's loader. New
processes get their tweaks from Burrow's loader; running ones keep theirs
until they restart.

What changes:

- ElleKit's `TweakLoader.dylib` is moved aside with `dpkg-divert`, so an
  ElleKit update does not bring it back, and Burrow's loader takes its
  place. ElleKit stays the hooking engine.
- Safe Mode starts working. When a tweak crashes a process, Safe Mode turns
  that tweak off in that process only, and says why.
- Per-app settings start working: in Codling, you can turn a tweak off in
  one app.

For the next 15 minutes, `burrowd` goes back to ElleKit's loader by itself
if SpringBoard crashes twice. At any time, it also goes back when a process
crashes inside Burrow's loader with no tweak to blame.

## 2. Switch the hooking engine

Once Burrow's loader is in use, as root:

```sh
burrowctl engine burrow
```

Then restart SpringBoard. Each of ElleKit's engine files that is there is
moved aside, all of them or none: `CydiaSubstrate.framework`,
`libsubstrate.dylib`, `libhooker.dylib` and `libblackjack.dylib`. Burrow's
engine takes their place. `libsubstitute` stays ElleKit's, since Burrow does
not provide its functions.

The engine has its own 15 minute trial. `burrowd` goes back to ElleKit's
engine if SpringBoard crashes twice, or if a process crashes outside any
library, as in a hook's trampoline. At any time, it also goes back when a
process crashes inside Burrow's engine with no tweak to blame.

## Checking what is in use

```sh
burrowctl status            # the loader and engine in use, Safe Mode and the trial
burrowctl loaded SpringBoard  # the loader, engine and tweaks in SpringBoard now
burrowctl tweaks            # every tweak: where it runs, its crashes, where it is off
burrowctl events            # what Safe Mode turned off, and why
burrowctl enable TWEAK      # turn a tweak back on
```

Codling's Burrow screen shows the same: the loader in use, the trial, Safe
Mode's events, and every tweak, with a switch for each app.

## Going back

Go back to ElleKit's engine first, then to its loader, as root:

```sh
burrowctl engine ellekit
burrowctl loader ellekit
```

Or, for the loader, tap **Go Back to ElleKit's Loader** in Codling. Restart
SpringBoard afterwards. Removing the Burrow package does both itself before
it removes anything.

## For tweak developers

Your tweak runs on Burrow as it is. Burrow follows ElleKit wherever ElleKit
and Cydia Substrate's documentation disagree, so that tweaks load where
they load today. These are the differences you may notice.

### Loading

- **Filters** combine as in ElleKit: `CoreFoundationVersion`, when present,
  must match, and then any one of `Bundles`, `Classes` and `Executables` is
  enough. `Mode` is accepted and changes nothing.
- **The old arm64e ABI.** Burrow's loader opens ElleKit's `OldABI.dylib`
  before the first tweak, as ElleKit's does. When the shim is not
  installed, Burrow skips arm64e tweaks built only with the old ABI and logs
  why, where ElleKit's loader would load them and crash. Rebuild with a
  current toolchain to drop the dependency.
- **Order.** Tweaks load in the order of their file names, compared byte by
  byte. A tweak manager (`IsTweakManager` set beside `Filter`) loads before
  the others.
- **Turning tweaks off.** Users turn a tweak off by its file name without
  `.dylib`, everywhere or in one process. Keep your file name stable between
  versions, or their settings no longer apply.
- **Safe mode variables.** `_MSSafeMode=1` or `_SafeMode=1` in a process's
  environment loads no tweaks. On Dopamine, the jailbreak itself acts on
  them before any loader runs, so nothing changes there.

### Hooking

- `MSHookFunction` and `MSHookMessageEx` behave as documented. When
  `MSHookFunction` cannot hook a function safely, it leaves it untouched,
  writes why to the system log, and sets your original pointer to the
  function itself, so calling it still works.
- The `options` of libhooker's `LHHookFunctions` and `LHPatchMemory` are
  ignored: Burrow chooses the patch itself.
- Hooks cannot be removed.
- Burrow's own functions report why a hook failed, and install a batch of
  hooks all together or not at all. [api.md](api.md) explains how to use
  them and still load under ElleKit.

### Crashes

While Burrow's loader opens your tweak, the thread is named
`Burrow: loading <tweak>`. A crash in your constructor is therefore blamed
on your tweak even before any of its code is on the stack. Safe Mode turns
a crashing tweak off only in the process it crashed, so a crash in one app
does not take your tweak out of SpringBoard. [safe-mode.md](safe-mode.md)
explains how blame is decided.
