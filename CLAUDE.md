# Working on Burrow

Burrow is an open-source tweak injection platform for jailbroken iOS, licensed
under Apache-2.0. Codling (github.com/Nexus-jb/codling) is the package manager
that installs it and shows its Safe Mode and crash reports.

## Rules

- **English only.** Everything committed here is English: code, identifiers,
  comments, commit messages, branch names, pull request text and documentation.
  Chats with the owner may happen in another language; never copy chat text
  into this repository. `scripts/check-text-policy.py` enforces this in CI.
- **Written from scratch.** Do not copy code from Cydia Substrate, libhooker,
  ElleKit, Dobby or any other hooking library. Implement the documented
  behaviour of their public APIs.
- **C and ARM64 assembly in injected code.** Nothing that is loaded into other
  processes may pull in the Swift or C++ runtimes.
- **Rely on the jailbreak's capabilities.** Burrow uses what the jailbreak
  provides to modify code pages. It does not bypass system protections itself.
- **Safety first.** Every change to the hooking engine, the loader or Safe Mode
  comes with tests. A hook that cannot be installed safely must fail cleanly and
  leave the target function untouched.
- **No dead features.** A feature lands when it works on a real device.
- **Licensing.** New source files start with
  `// SPDX-License-Identifier: Apache-2.0` (or `#` for scripts).
- **Never commit secrets**, signing keys or personal data.

## Workflow

- Work on a branch and open a pull request; the owner merges into `main`.
- Keep each pull request to one step of the work plan, and describe how it was
  tested (device, chip, iOS version, jailbreak).
