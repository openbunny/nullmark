<!-- SPDX-License-Identifier: MIT -->

# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately, not through a public issue: open
the repository's **Security** tab and choose **Report a vulnerability**. The
report is visible only to the maintainers.

Include the affected component (app, redaction core or CLI), the impact, the
macOS version and steps to reproduce. Describe the input PDF; do not attach it,
because it carries whatever its author put in it. A maintainer acknowledges the
report and coordinates a fix and disclosure.

## Scope

This policy covers the `nullmark` app, the redaction core in `CTask4PDF/` and
its standalone CLI. A vulnerability in MuPDF itself belongs to the MuPDF
project; this policy covers how `nullmark` calls it.

In scope: any input for which `t4_replace` returns 0 while the target remains on
a surface the verification scan covers, leaves a file at the output path on any
other outcome, or corrupts memory while parsing a PDF.
[README.md](README.md#security) states the guarantee.

Not a vulnerability: text drawn as an image, which has no text layer and is out
of scope, and the byte-level differences between input and output that
[README.md](README.md#what-preservation-means-at-the-byte-level) states. The app
runs without App Sandbox and the hardened runtime; the reason is in
[README.md](README.md#sandbox-and-hardened-runtime).

## Network behaviour

The app makes no network request, collects no telemetry and ships no remote
script or font. The standalone CLI runs under a Seatbelt profile that denies
network access.
