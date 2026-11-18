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
| `Bundles` | a bundle with one of these identifiers is loaded: the app itself or a framework it uses, such as `com.apple.UIKit` |
| `Executables` | the last component of the executable's path is one of these names |
| `Classes` | one of these Objective-C classes exists in the process |
| `CoreFoundationVersion` | `kCFCoreFoundationVersionNumber` is at least the first number and, if there is a second, below it |

Within one key, any entry may match. By default every key that is present
must match. With `Mode` set to `Any`, one matching key is enough.

A tweak is not loaded when:

- it has no filter, or its filter cannot be read;
- its `Filter` dictionary has none of the keys above;
- the library cannot be loaded. The loader logs the reason and goes on with
  the next tweak;
- in an arm64e process, its arm64e code is built for the old arm64e ABI and
  it has Objective-C classes or categories of its own (see below).

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
loader loads nothing.

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

## Tweaks built for the old arm64e ABI

Xcode 12 changed the arm64e ABI. Toolchains from before it, and some that
still only produce the old ABI, mark a library's arm64e code without the
pointer authentication ABI flag in its CPU subtype. Recent versions of the
Objective-C runtime authenticate class data that such a library does not
sign, and the process crashes while the runtime reads the library's classes,
before the tweak's constructor runs. Seen with SpringBoard on iOS 16.3.1:

    EXC_BAD_ACCESS (SIGBUS), Address size fault
    readClass(objc_class*, bool, bool) + 92   libobjc.A.dylib
    map_images_nolock + 3372                  libobjc.A.dylib
    dyld4::APIs::dlopen_from(...) + 1200      dyld
    burrow_loader_start + 2596                BurrowLoader.dylib

In arm64e processes the loader therefore reads the Mach-O headers of each
tweak it is about to load (`src/legacy_abi.c`). It skips a tweak whose
arm64e code, in a thin file or in any arm64e slice of a universal one, is
built for the old ABI and has a non-empty class or category list, and logs
that it needs a build with a current toolchain. Old-ABI tweaks without
classes or categories of their own, such as ones that only hook methods,
still load. In arm64 processes the arm64e code is not used, so nothing is
checked there.

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

## Testing

`make test-loader` (macOS) and the device package run `tests/loader_tests.c`.
`scripts/build-loader-tests.sh` builds a test set: a test build of the
loader that takes its paths from the environment, fifteen test tweaks with
filters from `tests/loader/TweakInject`, and two targets:

- `loader-target`: no bundle, the Objective-C class `BurrowLoaderPlainClass`,
  and no CoreFoundation of its own;
- `LoaderTarget.app`: the bundle identifier
  `com.nexusjb.burrow-tests.loader-target`, and it uses Foundation like an
  app.

Each test tweak tells the target when its constructor runs. The test program
runs both targets under eleven settings files and the two safe mode
variables, and checks which tweaks loaded and in what order. Among the test tweaks are one with no filter, one with an
unreadable filter, one with an empty filter, one that is not a library, a
tweak manager whose name sorts last, and filters in OpenStep format and
with `Mode` set to `Any`.

A last case runs `loader-target` with only `LegacyABI` in the tweak
directory: a tweak with a class of its own, a slice for the test's
architecture and an arm64e slice marked as built for the old ABI. In arm64e
processes the loader must skip it. Elsewhere it loads, and the test build of
the loader checks as if it were in an arm64e process when
`BURROW_TEST_ARM64E_CHECK` is `1`, so the check also runs on Macs.
`make test-legacy-abi` runs the unit tests of the header reading on any
host, with Mach-O files built in memory.

Device results:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.31 | All 20 loader checks passed for both architectures, with every other suite |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.48 | All 26 loader checks passed, with tweak managers and the safe mode variables |
