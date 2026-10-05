<!-- SPDX-License-Identifier: MIT -->

# Label taxonomy

Three prefixes: `type/*` classifies an issue, `area/*` locates it, `status/*`
tracks it through triage. Every issue and PR carries exactly one `type/*`
label; `area/*` and `status/*` are added during triage.

## type/*

| Label           | Meaning                                                            |
| --------------- | ------------------------------------------------------------------ |
| `type/bug`      | The app or the C core behaves differently from what it documents.  |
| `type/feature`  | A new behaviour.                                                   |
| `type/docs`     | README, CONTRIBUTING, or other documentation only.                 |
| `type/chore`    | Build, dependency, or repository maintenance.                      |
| `type/security` | A vulnerability report or hardening change.                        |

## area/*

| Label                | Covers                                                            |
| -------------------- | ----------------------------------------------------------------- |
| `area/app`           | The SwiftUI app in `App/Sources`                                  |
| `area/core`          | The redaction core in `CTask4PDF/`, including the CLI and fuzz harness |
| `area/tests`         | The pytest suite in `tests/` and `AppTests/`                       |
| `area/signing`       | `Signing.xcconfig`, bundle identifiers, and provisioning           |
| `area/dependencies`  | MuPDF, the OpenBunny theme package, and tool pins                  |
| `area/ci`            | GitHub Actions workflows and the `justfile` gates                  |
| `area/release`       | Release configuration and artefact signing                        |
| `area/docs`          | README, CONTRIBUTING, and other tracked docs                       |

## status/*

| Label                 | Meaning                                                         |
| --------------------- | --------------------------------------------------------------- |
| `status/needs-triage` | Default label on a new issue; a maintainer has not reviewed it. |
| `status/confirmed`    | A maintainer reproduced the bug or accepted the proposal.       |
| `status/blocked`      | Waiting on an external dependency, decision, or MuPDF pin.      |
| `status/wontfix`      | Closed without a change; the issue states why.                  |
