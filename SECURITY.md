# Security Policy

Burrow is loaded into almost every process on a jailbroken device, so a bug in
Burrow can affect the whole system. We treat security reports as a priority.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Report it privately through GitHub: open the **Security** tab of this
repository and choose **Report a vulnerability**. Include the Burrow version,
your device, iOS version and jailbreak, and the steps to reproduce the problem.

We will confirm that we received your report, keep you informed while we work
on a fix, and credit you in the release notes unless you prefer otherwise.

## In scope

- The hooking engine and its compatibility APIs
- The loader and its parsing of tweak filters
- Safe Mode and crash records
- Release packages and the build pipeline

## Verifying a release

Every release package comes with a build provenance attestation. Check it
before you install a package from anywhere other than an official repository:

```sh
gh attestation verify <package>.deb --repo Nexus-jb/burrow
```
