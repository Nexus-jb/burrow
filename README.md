# Burrow

A modern, open-source tweak injection platform for jailbroken iOS.

> **Status: early development.** Burrow is not ready for everyday use yet.
> Version 1.0 will follow a closed and a public beta.

Burrow loads tweaks into apps and system processes on jailbroken iPhones and
iPads. It is designed as a drop-in replacement for the injection libraries
tweaks already use: tweaks built against the Cydia Substrate or libhooker APIs
should run on Burrow without being rebuilt.

## What Burrow is built to do

The features below are the goals for version 1.0. Each one ships only when it
works on real devices.

- **Fast, reliable hooking** of C functions and Objective-C methods on arm64
  and arm64e, including pointer authentication.
- **Compatibility with existing tweaks** through the Substrate API
  (`MSHookFunction`, `MSHookMessageEx`, `MSFindSymbol`, `MSGetImageByName`) and
  the libhooker API.
- **Filter-based loading** from `/var/jb/usr/lib/TweakInject`, using the same
  property list filters tweaks ship today (bundles, executables and classes).
- **Per-app control**, so you can turn tweaks off for a single app, such as a
  banking app.
- **Smart Safe Mode.** When a tweak crashes SpringBoard, Burrow finds the tweak
  responsible, turns off only that tweak, and tells you which one and why.
- **Crash attribution.** Burrow records which tweak was involved in a crash, so
  that [Codling](https://github.com/Nexus-jb/codling) can send the report to the
  tweak's developer, only with your consent.
- **A small footprint.** The core is written in C and ARM64 assembly, so no
  extra language runtime is loaded into every process.

## Supported jailbreaks

| Scheme   | Package architecture | Examples                             |
| -------- | -------------------- | ------------------------------------ |
| rootless | `iphoneos-arm64`     | Dopamine, palera1n (rootless mode)   |
| roothide | `iphoneos-arm64e`    | Dopamine (RootHide)                  |

iOS 15 and later. Rootful jailbreaks are not planned for 1.0.

## Building

The hooking engine builds with `make` on macOS or Linux and runs its tests on
arm64:

```sh
make          # build/libburrow.a
make test     # all tests (arm64 macOS or Linux)
```

On another Linux machine, the tests can run under QEMU:

```sh
make test CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
```

To run the tests on a jailbroken iPhone, build the test package on a Mac
with Xcode, ldid and dpkg, install it, and run `burrow-tests` on the device:

```sh
make ios-tests-package PACKAGE_VERSION=0.0.0~dev.1
```

[docs/hooking.md](docs/hooking.md) explains how hooks are installed and which
rules keep them safe. [docs/loader.md](docs/loader.md) explains how the loader
picks the tweaks for each process, and [docs/safe-mode.md](docs/safe-mode.md)
how Safe Mode and the crash log find the tweak behind a crash. Release packages will be built on GitHub Actions,
signed, and published with build provenance attestations.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first.

## Security

Burrow runs inside almost every process on the device. Please report
vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## License

Burrow is licensed under the [Apache License 2.0](LICENSE). The names "Burrow"
and "Codling" and their logos are not covered by the license (see
[NOTICE](NOTICE)).

Burrow is an independent project. It is not affiliated with or endorsed by the
authors of Cydia Substrate, libhooker or ElleKit.
