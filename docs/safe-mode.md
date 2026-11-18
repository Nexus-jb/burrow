# How Safe Mode works

When a tweak crashes a process, Safe Mode finds that tweak and turns it off
in that process only, and records why. The code is in `safemode/`. It runs
outside the crashing process, so nothing is added to the processes tweaks
are loaded into, and the crash reporters of apps keep working.

## Where the information comes from

iOS and macOS write a crash report for every crash: an `.ips` file with a
JSON header line and a JSON body. Safe Mode reads:

- the process name, its bundle identifier and the time;
- the exception type and signal, and an uncaught exception's name and
  reason when the report has them (reports from iOS 16 do not);
- the crashed thread's frames and, for an uncaught Objective-C exception,
  the backtrace where it was thrown;
- every loaded image's path and UUID.

Reports hide parts of some paths, such as `/Users/USER/*/Foo.dylib`, so
Safe Mode recognizes tweaks by UUID: it reads the UUIDs of every tweak in
the tweak directory and matches them against the report's images. A path
inside the tweak directory is a second way to recognize one.

## Who is to blame

Safe Mode walks the frames from the crash site down, first in the backtrace
of an uncaught exception, then in the crashed thread:

- The first tweak found is to blame.
- If the process's own code comes first (its main executable, or an app in
  the app container), the crash is the app's own, and no tweak is blamed.
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

## Running it

The library is built and tested here. The daemon that hands it every new
crash report is installed together with the loader, in a later step of the
work plan.

## Testing

`make test-safemode` (macOS) and the device package run
`tests/safemode_tests.m`. It has two parts:

- Hand-written reports in `tests/safemode/fixtures`: a crash in a tweak, an
  uncaught exception thrown by a tweak through a jailbreak library, both
  exception formats, a crash in the app's own code, a tweak frame too deep
  to blame, a crash loop, a process without tweaks, a hang report, a broken
  report, the same report twice, and settings that are not valid.
- Real crashes: `crash-target` loads three test tweaks through the test
  build of the loader. `SegvTweak` writes through a null pointer and
  `ThrowTweak` throws an uncaught exception; `Innocent` does nothing. The
  test waits for the system's crash report, hands it to Safe Mode, and
  checks that the crashing tweak was turned off and `Innocent` was not. It
  deletes the reports it made.

Device results:

| Device | Chip | iOS | Jailbreak | Build | Result |
| ------ | ---- | --- | --------- | ----- | ------ |
| iPhone 14 Pro Max | A16 (arm64 and arm64e tests) | 16.3.1 | Dopamine, rootless | 0.0.0~dev.39 | All 63 checks passed for both architectures, with real crash reports from iOS |
