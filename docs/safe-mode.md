# How Safe Mode and the crash log work

When a tweak crashes a process, Safe Mode finds that tweak and turns it off
in that process only, and records why. The crash log keeps every crash of a
process with tweaks loaded, with the tweak to blame and the package it came
from. The code is in `safemode/`:

| File | Contents |
| ---- | -------- |
| `crash_report.m` | Reads crash reports |
| `crash_analysis.m` | Finds the tweaks in a report and the one to blame, for both of the others |
| `safe_mode.m` | Turns the tweak to blame off |
| `crash_log.m` | Keeps the crash log |
| `packages.m` | Finds the package that installed a tweak in the dpkg database |

All of it runs outside the crashing process, so nothing is added to the
processes tweaks are loaded into, and the crash reporters of apps keep
working.

## Where the information comes from

iOS and macOS write a crash report for every crash: an `.ips` file with a
JSON header line and a JSON body. Safe Mode reads:

- the process name, its bundle identifier and the time;
- the exception type and signal, and an uncaught exception's name and
  reason when the report has them (reports from iOS 16 do not);
- the crashed thread's frames and, for an uncaught Objective-C exception,
  the backtrace where it was thrown;
- the path and UUID of each image on the threads' stacks. Reports list only
  those images, not everything the process loaded;
- the name of the crashed thread, which says when Burrow's loader was
  opening a tweak (below).

Reports hide parts of some paths, such as `/Users/USER/*/Foo.dylib`, so
Safe Mode recognizes tweaks by UUID: it reads the UUIDs of every tweak in
the tweak directory and matches them against the report's images. A path
inside the tweak directory is a second way to recognize one.

## What Burrow's loader leaves in a report

While Burrow's loader opens a tweak, it names the thread
`Burrow: loading <tweak>`, and reports keep the name of every thread. A
crash in dyld or the Objective-C runtime while a tweak was opened, before
any of its code ran, therefore names that tweak, though no tweak is on a
stack. Such a crash is how a tweak built with the old arm64e ABI fails
without the shim (see [loader.md](loader.md)). Thread names are cut at 63
bytes; a cut name is completed from the tweak directory when only one tweak
starts with it.

A message in a library's `__DATA,__crash_info` section would not do: the
crash reporter of macOS 14 and later leaves out the messages of libraries
outside the shared cache, as the tests showed on macOS 15.

## Who is to blame

Safe Mode walks the frames from the crash site down, first in the backtrace
of an uncaught exception, then in the crashed thread:

- The first tweak found is to blame.
- If the process's own code comes first (its main executable, or an app in
  the app container), the crash is the app's own, and no tweak is blamed.
- Without a tweak on the stacks, a crash on the thread where Burrow's loader
  was opening a tweak is blamed on that tweak, and its reason says so.
- Frames from the system, from Burrow and from other libraries of the
  jailbreak are passed over, but at most 12 of them. A tweak further from
  the crash is not blamed: a tweak that hooks a busy method appears in many
  backtraces without causing the crash. Frames in the crash machinery
  (`abort`, `libc++abi`, `libobjc`) do not count.

When one tweak is to blame, Safe Mode adds it to `DisabledInProcesses` in
the loader settings (see [loader.md](loader.md)) for the crashed process,
named by its bundle identifier or, without one, its executable name. The
tweak keeps working everywhere else.

## Repeated crashes

When a process crashes three times within two minutes with tweaks loaded
and no single tweak to blame, Safe Mode turns every tweak off in that
process (`*`). This is the safety net for crash loops it cannot explain,
such as SpringBoard crashing on every start.

Reports from processes with no tweak loaded, and reports that are not
crashes (hangs, memory reports), are ignored. Each report is handled once.

## What it records

Each change is recorded as an event with the date, the process, the tweak
(or `*`), the report's file name, and a reason people can read, such as:

```
turned off Foo in com.apple.springboard: EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib (-[FooView layoutSubviews] + 16)
turned off Bar in com.example.app: an uncaught exception (SIGABRT) in Bar.dylib + 0x1a2c
turned off every tweak in backboardd: crashed 3 times within 120 seconds, and no single tweak was to blame
```

The events are for the package manager to show, next to a way to turn the
tweak back on. The last 100 events are kept.

Safe Mode changes the loader settings under an exclusive lock on
`<settings>.lock`, and anything else that writes them must take the same
lock. If the settings exist but are not valid, Safe Mode leaves them alone:
the loader already loads nothing until they are fixed.

## The crash log

Safe Mode only acts when it must. The crash log records every crash of a
process with tweaks loaded, also when no tweak was to blame, so the person
and later the tweak's developer can see what happened. Each entry holds:

- the date, the process and its bundle identifier;
- the tweak to blame, if any, and every tweak that was loaded;
- for each of those tweaks, the package that installed it and its version,
  from the dpkg database (`/var/jb/var/lib/dpkg` on a rootless jailbreak);
- the same one-line reason Safe Mode uses;
- the system version and the device model;
- a copy of the crash report, because the system deletes old ones.

For example:

```
com.apple.springboard: Foo (com.example.foo 1.2): EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib (-[FooView layoutSubviews] + 16)
com.example.app: no single tweak to blame (loaded: Bar, Foo): EXC_BAD_ACCESS (SIGSEGV) in Example (-[ExampleModel load] + 0)
```

The log keeps the 50 newest entries and deletes the copies of older ones.
Each crash is recorded once. Nothing leaves the device: sending a report to
a tweak's developer needs the person's consent and is a separate feature.

## Running it

The Burrow package runs `burrowd`, a launch daemon. It watches
`/var/mobile/Library/Logs/CrashReporter`, where the system writes the crash
reports of every process, root's included, and hands every new report to
the crash log. On its first start it reads the reports already there.

Safe Mode acts only once Burrow's loader is the one loading tweaks: before
that, turning a tweak off in Burrow's settings would change nothing. It
then handles crashes from the moment Burrow's loader took over, never older
ones.

`burrowctl` shows the state:

```
burrowctl status       the tweak loader and hooking engine in use, burrowd,
                       the reports it has read, the crash log and Safe Mode
burrowctl crashes [N]  the N newest crashes with tweaks loaded (10)
burrowctl events       what Safe Mode turned off, and why
burrowctl why NAME     the newest crash report of the process NAME, among
                       the system's and the crash log's copies (or a
                       report file): the exception, the tweaks found, the
                       one to blame, the tweak Burrow's loader was opening,
                       the images on the stacks that are not Apple's, and
                       the crashed thread
burrowctl loaded NAME  the tweak loader, hooking engine and tweaks in the
                       running process NAME. Burrow's loader is not mapped
                       once the jailbreak closes it; a process started after
                       the switch is shown as loaded by it
burrowctl check        the tweaks and the libraries they load that use the
                       old arm64e ABI, whether ElleKit's OldABI shim is
                       installed, the tweaks with a CoreFoundationVersion
                       range, and the tweak managers
burrowctl loader burrow|ellekit
                       which loader /var/jb/usr/lib/TweakLoader.dylib is
                       (root only)
```

The state lives in `/var/jb/var/lib/burrow`: `crashes/` for the crash log,
`safe-mode.plist` for Safe Mode, and `burrowd.plist` for what burrowd has
read.

## Testing

`make test-safemode` (macOS) and the device package run
`tests/safemode_tests.m`. It has two parts:

- Hand-written reports in `tests/safemode/fixtures`: a crash in a tweak, an
  uncaught exception thrown by a tweak through a jailbreak library, both
  exception formats, a crash in the app's own code, a tweak frame too deep
  to blame, a crash loop, a process without tweaks, a hang report, a broken
  report, the same report twice, and settings that are not valid.
- The crash log with the same reports and a small dpkg database in
  `tests/safemode/dpkg`: the tweak and package names, the kept copy, the
  skipped reports, and the oldest entries going first.
- The burrowd service with the same reports: each report handled once,
  and Safe Mode only for crashes after the date it was turned on.
- Real crashes: `crash-target` loads three test tweaks through the test
  build of the loader. `SegvTweak` writes through a null pointer and
  `ThrowTweak` throws an uncaught exception; `Innocent` does nothing. The
  test waits for the system's crash report and hands it to Safe Mode and
  the crash log. It checks that the crashing tweak was turned off and
  `Innocent` was not, and that the log names the crashing tweak and its
  package. On a jailbroken device that is the test package itself, read
  from the real dpkg database. The test deletes the reports it made.

Device results:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.39 | All 63 checks passed for both architectures, with real crash reports from iOS |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.42 | All 94 checks passed for both architectures; the crash log named each crashing tweak and its package from the device's dpkg database |
| iPhone 14 Pro Max | A16 | 16.3.1 | Dopamine, rootless, ElleKit loading tweaks | 0.0.0~dev.48 | burrowd read the device's 123 crash reports; `burrow-tests probe` crashed the probe through ElleKit, and burrowd logged the crash within seconds, blaming the probe tweak and naming its package |

`burrow-tests probe` checks burrowd itself on a device with the Burrow
package installed. The test package puts the tweak `BurrowCrashProbe` in the
system's tweak directory, with a filter for `burrow-crash-probe` only. The
command runs that program: the tweak loader in use, whichever it is, loads
the tweak, the tweak crashes the program, and the command waits for burrowd
to log the crash and blame the probe tweak.
