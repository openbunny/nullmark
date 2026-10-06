<!-- SPDX-License-Identifier: MIT -->

# Documentation index

Each fact has one owning document. Another document points to the owner and does
not restate the fact. `git ls-files '*.md'` prints the live document list; a
tracked document missing from the table below fails review of the change that
adds it.

| Document                                                                | Owns                                                                                                           |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [README.md](../README.md)                                               | project summary, install, the guarantee, byte-identity claims, sandbox and hardened-runtime rationale, licence |
| [docs/design.md](design.md)                                             | layout, replacement and scrubbed surfaces, verification scan, MuPDF dependency, known limitations              |
| [tests/README.md](../tests/README.md)                                   | test prerequisites, fixtures and the cases built on them                                                       |
| [SECURITY.md](../SECURITY.md)                                           | vulnerability reporting, scope, network behaviour                                                              |
| [CONTRIBUTING.md](../CONTRIBUTING.md)                                   | contributor workflow, commit and sign-off rules                                                                |
| [MAINTAINERS.md](../MAINTAINERS.md)                                     | maintainers and succession                                                                                     |
| [AGENTS.md](../AGENTS.md)                                               | rules for automated contributors                                                                               |
| [.github/labels.md](../.github/labels.md)                               | label taxonomy                                                                                                 |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md)                             | conduct rules                                                                                                  |
| [.github/PULL_REQUEST_TEMPLATE.md](../.github/PULL_REQUEST_TEMPLATE.md) | pull request template                                                                                          |
| `justfile`                                                              | the gate set; `just --list` prints it                                                                          |
| `mise.toml`                                                             | tool and toolchain versions                                                                                    |
| `NOTICE`                                                                | third-party notices                                                                                            |
| `.github/workflows/`                                                    | CI configuration                                                                                               |

[docs/README.md](README.md) owns this table.
