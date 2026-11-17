# Contributing to Burrow

Thank you for helping. This page explains how we work.

## Language

Burrow is developed in English. Code, identifiers, comments, commit messages,
pull request titles and descriptions, issues and documentation must all be in
English. The `Text policy` check enforces this on every push and pull request.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on
  the approach.
- Keep each pull request focused on one change.
- Never commit secrets, signing keys or personal data.
- Do not copy code from other hooking libraries. Write it from the documented
  behaviour of the APIs instead.

## Pull requests

- Describe what changed and why, and how you tested it. Include the device, its
  chip (arm64 or arm64e), the iOS version and the jailbreak.
- All checks must pass before review.
- Changes to the hooking engine, the loader or Safe Mode need tests and get an
  extra review, because a mistake there can crash every process.

## Licensing of contributions

By submitting a contribution, you agree that it is licensed under the
[Apache License 2.0](LICENSE), as described in Section 5 of the license.

## Code of conduct

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
