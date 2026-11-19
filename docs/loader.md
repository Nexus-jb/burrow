# How the tweak loader works

The loader is a small C library. When it is loaded into a process, it loads
each tweak in the tweak directory whose filter matches that process, unless
the user has turned the tweak off there. The source is `src/loader.c`.

On a rootless jailbreak the tweak directory is `/var/jb/usr/lib/TweakInject`
and the loader settings are `/var/jb/etc/burrow/loader.plist`. The loader is
built and tested here; it replaces the jailbreak's own tweak loader in a
later step of the work plan, together with Safe Mode.

## Filters

A tweak `Foo.dylib` comes with a filter `Foo.plist` beside it, in the format
Cydia Substrate documented. The property list may be XML, binary or
OpenStep. Its `Filter` dictionary can hold:

| Key | Matches when |
| --- | ------------ |
| `Bundles` | a bundle with one of these identifiers, or the identifier in lower case, is loaded: the app itself or a framework it uses, such as `com.apple.UIKit` |
| `Executables` | the last component of the executable's path is one of these names |
| `Classes` | one of these Objective-C classes exists in the process |
| `CoreFoundationVersion` | one number: `kCFCoreFoundationVersionNumber` is at least that number; two numbers: never (see below) |

Within one key, any entry may match. The keys combine the way ElleKit, the
tweak loader that rootless tweaks are made and tested with, combines them:

- `CoreFoundationVersion`, when present, must match;
- then any one of `Bundles`, `Classes` and `Executables` is enough.

Cydia Substrate documented that every key present must match unless `Mode`
is `Any`. Burrow follows ElleKit instead, so that tweaks load where they load
today. `Mode` is accepted and changes nothing.

A tweak is not loaded when:

- it has no filter, or its filter cannot be read;
- its `Filter` dictionary has none of `Bundles`, `Classes` and
  `Executables`, even if it has `CoreFoundationVersion`, as in ElleKit;
- its `CoreFoundationVersion` holds two numbers. Cydia Substrate documented
  them as a range, but ElleKit's loader never loads such a tweak, so none
  of them has run on a jailbreak that uses ElleKit. Burrow does the same, so
  that switching loaders does not start loading untested tweaks. Any other
  `CoreFoundationVersion` that is not one number sets no condition, as in
  ElleKit;
- the library cannot be loaded. The loader logs the reason and goes on with
  the next tweak.

Before the first tweak that is not a tweak manager, the loader opens
`/var/jb/usr/lib/ellekit/OldABI.dylib` when it is installed, as ElleKit's
loader does. Tweaks built for arm64e with the ABI from before iOS 14 crash
without it, in the Objective-C runtime, while they are loaded. Tweaks are
opened with `RTLD_LAZY`, the mode ElleKit's loader uses.
`burrowctl check` lists the tweaks, and the libraries they load, with the old
ABI, and the tweaks with two `CoreFoundationVersion` numbers.

In arm64e processes, when the shim is not installed or cannot be loaded,
the loader skips tweaks whose arm64e code uses only the old ABI and logs
why, instead of letting them crash the process. A tweak with a slice for
each ABI loads the new one and is not skipped. The tests check the reading
of the ABI from Mach-O headers.

While the loader opens a tweak, it names the thread `Burrow: loading
<tweak>` and then gives the thread its name back, so that a crash report
names the tweak even when the crash comes before any of its code runs (see
[safe-mode.md](safe-mode.md)).

Tweaks are loaded in the order of their names, compared byte by byte, so
`000First.dylib` loads before `Alpha.dylib`. Files whose names start with a
dot are skipped.

A tweak whose property list sets `IsTweakManager` to true, beside `Filter`,
is a tweak manager: a tweak that decides about other tweaks, such as one
that turns tweaks off per app. Matching tweak managers are loaded before
every other tweak, whatever their names, and only when at least one other
tweak is to be loaded.

When the environment variable `_MSSafeMode` or `_SafeMode` is `1`, the
convention from Cydia Substrate for starting a process without tweaks, the
loader loads nothing. On Dopamine the loader does not see them: its spawn
hook removes both variables from a new process's environment and injects
nothing into that process, so no tweak loader runs there at all.

## Turning tweaks off

The loader settings can only turn tweaks off; they never load a tweak that
its filter does not match. A tweak is named by its file name without
`.dylib`, and `*` stands for every tweak:

```xml
<dict>
    <key>DisabledTweaks</key>
    <array>
        <string>Foo</string>
    </array>
    <key>DisabledInProcesses</key>
    <dict>
        <key>com.example.bank</key>
        <array>
            <string>*</string>
        </array>
        <key>SpringBoard</key>
        <array>
            <string>Bar</string>
        </array>
    </dict>
</dict>
```

`DisabledTweaks` turns tweaks off in every process. `DisabledInProcesses`
turns them off in one process, named by its bundle identifier or by its
executable name.

When there are no settings, nothing is turned off. When the settings exist
but cannot be read, or a key has the wrong type, the loader loads no tweaks
at all and logs why. The settings may be what keeps tweaks out of a banking
app, so a broken file must not load them by mistake.

## Processes without CoreFoundation

Most processes load CoreFoundation themselves. In a process that does not,
such as a command-line tool, CoreFoundation comes in with the loader. In
that case CoreFoundation's bundle functions can throw an exception (seen on
macOS 15), so the loader does not call them. It reads the identifiers of the
main bundle and of the loaded bundles from their `Info.plist` files instead.
Such a process has few images, so this is quick. dyld lists images in load
order, so the loader can tell which case it is in: CoreFoundation is listed
before the loader only if the process loaded it first.

A process with no tweaks in the tweak directory costs one directory read:
the loader returns before it reads any property list.

## Switching from ElleKit's loader

On a jailbreak that uses ElleKit, the Burrow package installs the loader
beside ElleKit's and changes nothing. As root, `burrowctl loader burrow`
switches:

- `dpkg-divert --package com.nexusjb.burrow --rename` moves ElleKit's
  `/var/jb/usr/lib/TweakLoader.dylib` aside to
  `/var/jb/usr/lib/TweakLoader.ellekit.dylib`, so that an ElleKit update
  does not put its loader back, and the path becomes a link to
  `/var/jb/usr/lib/burrow/BurrowLoader.dylib`. The jailbreak loads it into
  every new process. ElleKit stays the hooking engine.
- It needs burrowd running, and starts a 15 minute trial.

burrowd guards the switch and goes back to ElleKit's loader by itself
(`burrowctl loader ellekit` does the same by hand):

- at any time, when a process crashes with Burrow's loader on the crashed
  thread and no tweak to blame. A crash with a tweak to blame, such as a
  tweak crashing in its constructor while the loader opens it, is that
  tweak's, and Safe Mode turns it off instead;
- during the trial, when SpringBoard crashes twice.

`burrowctl status` shows the loader, the trial and the guard's reason when
it went back. Removing the package goes back to ElleKit's loader first.

The hooking engine switches the same way, after the loader: `burrowctl
engine burrow` diverts each of ElleKit's links to its engine that is there,
`/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` and
`libsubstrate.dylib`, `libhooker.dylib` and `libblackjack.dylib` in
`/var/jb/usr/lib`, to a name with `.ellekit` in it, and links each to
`/var/jb/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate`: all of
them or none. `libsubstitute` stays ElleKit's, since Burrow does not
provide its interface. Tweaks that are already running keep the engine
they loaded. The engine's guard, with its own 15 minute trial, goes back to
ElleKit's engine:

- at any time, when a process crashes with Burrow's engine on the crashed
  thread and no tweak to blame;
- during the trial, when a process crashes outside any image, as in the
  trampoline of a hook, or when SpringBoard crashes twice.

Before switching, `burrowctl check` reads the symbols each tweak, and each
library it loads, imports from the engine's libraries, and looks each one
up in Burrow's engine.

Device results of the engine switch:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader | 0.0.0~dev.79 | `burrowctl check`: 20 tweaks; 14 of them import 4 symbols from the engine, and Burrow's engine has all four |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader | 0.0.0~dev.80 | `burrowctl engine burrow` and a respring: SpringBoard ran, and the trial ended without the guard going back |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader and engine | 0.0.0~dev.81 | `burrowctl loaded SpringBoard` after a respring: Burrow's engine mapped, with the ten tweaks, eight of which link the engine. Before the respring it showed no engine: the package had been reinstalled while SpringBoard ran, and a replaced file has no path left in the process, which `loaded` now explains |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader and engine | 0.0.0~dev.81 | Settings ran with Burrow's engine and PreferenceLoader, and showed the tweaks' settings; MessageDateTime worked in Messages |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader and engine | 0.0.0~dev.82 | `burrow-tests`: every suite passed for arm64 and arm64e (loader 33, Safe Mode 171) |

Device results of the switch:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, ElleKit | 0.0.0~dev.54 | SpringBoard crashed in the Objective-C runtime while Burrow's loader opened a tweak; the guard went back to ElleKit's loader within seconds. The likely cause: a tweak built with the old arm64e ABI, which ElleKit's loader opens the OldABI shim for |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, ElleKit | 0.0.0~dev.68 | After the loader opened the shim like ElleKit's and that tweak was rebuilt with the current ABI, SpringBoard ran with Burrow's loader, with the ten tweaks ElleKit's loader loads into it |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, Burrow's loader | 0.0.0~dev.72 | `burrow-tests probe`: Safe Mode turned the probe tweak off in the probe and `burrowctl enable` turned it back on, but the guard also went back to ElleKit's loader, since the crash had Burrow's loader on the stack. The guard now leaves crashes with a tweak to blame to Safe Mode |

## Testing

`make test-loader` (macOS) and the device package run `tests/loader_tests.c`.
`scripts/build-loader-tests.sh` builds a test set: a test build of the
loader that takes its paths from the environment, seventeen test tweaks with
filters from `tests/loader/TweakInject`, and two targets:

- `loader-target`: no bundle, the Objective-C class `BurrowLoaderPlainClass`,
  and no CoreFoundation of its own;
- `LoaderTarget.app`: the bundle identifier
  `com.nexusjb.burrow-tests.loader-target`, and it uses Foundation like an
  app.

Each test tweak tells the target when its constructor runs. The test program
runs both targets under eleven settings files and the two safe mode
variables, which the target sets itself before it opens the loader since
Dopamine removes them on spawn, and checks which tweaks loaded and in what order. Among the test tweaks are one with no filter, one with an
unreadable filter, one with an empty filter, one that is not a library, a
tweak manager whose name sorts last, a filter matched by either of two
keys, a bundle identifier in another case, a filter with only
`CoreFoundationVersion`, one with a `CoreFoundationVersion` range that
includes the running version, a stand-in for the old ABI shim, and filters in OpenStep format and with `Mode` set
to `Any`.

Device results (the 26 checks of 0.0.0~dev.48 ran on CI only):

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.31 | All 20 loader checks passed for both architectures, with every other suite |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless, Burrow's loader as the tweak loader | 0.0.0~dev.70 | 29 of 33 loader checks passed for both architectures. The four safe mode cases failed because Dopamine removed the variables before the target started; the tests now have the target set them itself |
