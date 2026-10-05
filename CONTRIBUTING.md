<!-- SPDX-License-Identifier: MIT -->

# Contributing

How to submit a change to an OpenBunny repository.

## Development

- Use the toolchain declared by the repository. `just install` installs it and
  the git hooks in `lefthook.yml`: `fmt-check`, `lint`, `typecheck` and
  `secrets` run before each commit, `just check` before each push.
- Run `just check` before opening a pull request.
- Add tests for behaviour added or fixed, using local substitutes for devices,
  accounts, and network peers.
- Follow the repository's `REUSE.toml` and existing SPDX headers for new files.

## Commits and pull requests

- One logical change per commit. Use a Conventional Commits header such as
  `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, or `chore:`.
- The pull request states what changed and why, and links related issues.
- Do not weaken a gate to make it pass. Fix the cause, or explain why the gate
  is wrong.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by` trailer, certifying you wrote it or
otherwise have the right to submit it under the
[Developer Certificate of Origin](https://developercertificate.org/). Add it
with `git commit --signoff` (or `-s`). These repositories do not use a
Contributor License Agreement; the DCO is the only requirement.

## Reporting bugs

Open an issue with the exact command run, the behaviour observed, and the
expected result. For a security report, follow [SECURITY.md](SECURITY.md)
instead.
