<!-- SPDX-License-Identifier: MIT -->

# Contributing

How to build, test, and submit a change to `nullmark`.

## Contents

- [Development](#development)
- [Commits and pull requests](#commits-and-pull-requests)
- [Releases](#releases)
- [Developer Certificate of Origin](#developer-certificate-of-origin)
- [Security-sensitive changes](#security-sensitive-changes)
- [Reporting bugs](#reporting-bugs)

## Development

- Install the toolchain and the git hooks once per clone: `just install`.
  `mise.toml` pins the tools. Xcode, and LLVM and cppcheck under
  `/opt/homebrew`, come from the machine; `CMakeLists.txt` pins MuPDF; the header of the `justfile` lists
  them.
- `lefthook.yml` runs `fmt-check`, `lint`, `typecheck` and `secrets` before each
  commit and `just check` before each push.
- Run `just check` before opening a pull request. It stops at the first failure.
  `just --list` prints the gates; the `justfile` owns the set. The CI workflow
  runs `just ci-check`, which runs `just install` and then the gates.
- Every change ships tests for the behaviour it adds or fixes, using local
  substitutes for devices, accounts and network peers. A new decoder of PDF
  input also ships a libFuzzer target under `CTask4PDF/fuzz/` and a seed in the
  committed corpus.
- A change to behaviour changes the document that describes it in the same pull
  request. [docs/README.md](docs/README.md) lists which document owns which
  fact.
- A new file follows `REUSE.toml` and the existing SPDX headers. `just reuse`
  checks licensing metadata.

## Commits and pull requests

- One logical change per commit. Use Conventional Commits headers: `feat:`,
  `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- The pull request states what changed and why, and links related issues.
- Do not weaken a gate to make it pass: no lowered floor, loosened assertion,
  deleted case or widened suppression. Fix the cause, or say why the gate is
  wrong.

## Releases

A release is source only: a `vX.Y.Z` tag on `main` and a GitHub release whose
notes list the changes since the previous tag. No build of the app is attached.

1. Set `MARKETING_VERSION` in `project.yml` to `X.Y.Z` and raise
   `CURRENT_PROJECT_VERSION` by one, in a `chore: release X.Y.Z` commit.
2. Run `just check`.
3. Create the release with `gh release create vX.Y.Z --target main
   --generate-notes`.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by` trailer, certifying you wrote it or
otherwise have the right to submit it under the
[Developer Certificate of Origin](https://developercertificate.org/). Add it
with `git commit --signoff` (or `-s`). This project does not use a Contributor
License Agreement; the DCO is the only requirement.

## Security-sensitive changes

A change that touches the replacement, the verification scan, the save path or
the output-file handling of `t4_replace` states in the pull request whether the
guarantee in [README.md](README.md#security) still holds and whether byte
identity of the four fields in
[README.md](README.md#what-preservation-means-at-the-byte-level) still holds. To
report a vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening an
issue.

## Reporting bugs

Open an issue with the exact steps run, the observed behaviour including any
error text and residual-text report, the expected result, the nullmark version,
and the macOS version and architecture. Describe the input document, the text
and layout that trigger the bug; do not attach it or a screenshot of it. For a security
report, follow [SECURITY.md](SECURITY.md) instead.
