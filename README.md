<!-- SPDX-License-Identifier: MIT -->

# nullmark

macOS app that removes a target string from a PDF and verifies that the string
is absent from every surface of the output.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The purpose is removing a deadname from a person's own documents after a legal
name change. The old text is removed from the page and from the document
metadata, and the new text is drawn or substituted in its place. Only
occurrences of the target change; every other field keeps the content it had.
That is a field-level guarantee, not whole-file byte identity. See
[What preservation means at the byte level](#what-preservation-means-at-the-byte-level).

## Table of contents

- [What it does](#what-it-does)
- [Install](#install)
- [Security](#security)
- [What preservation means at the byte level](#what-preservation-means-at-the-byte-level)
- [Sandbox and hardened runtime](#sandbox-and-hardened-runtime)
- [Network behaviour](#network-behaviour)
- [Development](#development)
- [Documentation](#documentation)
- [License](#license)

## What it does

The old string is removed from the page content stream, not covered. After a
replacement, the old string does not appear in the output's text, in a search,
or in the decompressed content bytes. The replacement is drawn as vector text in
the run's own font, size, colour and position. Where that font has no glyph for
the new text, a fallback font is embedded so the character still renders.

The target is also scrubbed from the Info dictionary values, the XMP metadata
packet, outline (bookmark) titles, annotation text and form-field values.
[docs/design.md](docs/design.md#replacement-and-scrubbed-surfaces) lists every
scrubbed surface and the string encodings covered.

The app calls the C core directly. `PDFEngine` is the only code that calls
`t4_replace`, and `EditorModel.apply()` calls `PDFEngine.replace`. `PDFMetadata`
is not on that path: `EditorModel.load()` builds it from the opened document as
a read-only summary for display.

Text drawn as an image, such as a scan, has no text layer and is out of scope.
The app does not perform OCR.

## Install

No release exists. Build from a clone:

```sh
just install
just xctest
```

`just install` installs the toolchain pinned in `mise.toml`, the Python
environment from `tests/uv.lock` and the git hooks from `lefthook.yml`. Xcode,
and MuPDF, LLVM (clang-format, clang-tidy, LeakSanitizer, libFuzzer, llvm-cov)
and cppcheck under `/opt/homebrew`, come from the machine; the header of the
`justfile` lists them. `just --list` prints every recipe.

`Signing.xcconfig` builds ad-hoc signed with no team.

## Security

`t4_replace` returns 0 only when the output reopens, re-parses, and an
independent scan finds zero occurrences of the target on every surface: page
text, decoded string values, and the decompressed bytes of every content,
object-graph and embedded-file stream, in the target's UTF-8, UTF-16BE and
UTF-16LE encodings. If the target survives on any surface, or a surface cannot
be read back, the output file is deleted and the call returns a failure. A
return of 0 with a residual count above 0 is a failure the caller must treat as
one.

A surface the rewrite cannot reach, such as an embedded file or an appearance
stream that draws the text as its own content, is detected by the scan and
refused. [docs/design.md](docs/design.md#known-limitations) states each
limitation. See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## What preservation means at the byte level

`t4_replace` saves through `pdf_save_document` with garbage collection and
recompression on: a full, non-incremental rewrite that renumbers every object in
the file and recompresses untouched streams. The output is not a byte-for-byte
copy of the input with only the target's occurrences changed. Object numbers,
the xref layout and stream encodings can differ even where no scrubbing touched
that content.

The guarantee is field-level: every non-target value keeps the content it had,
nothing is dropped or altered, and only occurrences of the target change. For a
file whose target lives only in the page text, four fields are also asserted
byte-identical between input and output by `test_replace_preserves_metadata` in
`tests/test_redactor.py`: the header version line, the Info dictionary (compared
with whitespace normalized by `pdfutil.normalize_ws`), the XMP metadata stream
payload, and both `/ID` array elements. Nothing beyond those four is claimed to
be byte-identical. The comparison runs on `mutool clean -d` output rather than
the CLI's raw bytes, because the raw file's object numbering and compression
differ from the input's.

The output has no second `%%EOF`, no `/Prev` and no MuPDF version string. It
keeps the versionless `% Written by MuPDF` comment that the save writes.

Filesystem metadata (dates, permissions, extended attributes) is reapplied on
export. `FileMetadata.apply` also strips the `com.apple.quarantine` and
`com.apple.provenance` extended attributes the OS adds to the exported file, so
the export does not carry a record of the machine that produced it.

## Sandbox and hardened runtime

The app does not adopt App Sandbox (no `com.apple.security.app-sandbox` in
`App.entitlements`) and disables the hardened runtime (`ENABLE_HARDENED_RUNTIME`
is `NO` in `project.yml`). Both are dropped for the same root cause:
`libmupdf.dylib` lives outside the bundle (`/opt/homebrew/lib`), is neither
Apple-signed nor vendored into it, and:

- the hardened runtime's library validation refuses to load a dylib not signed
  with the app's own Team ID;
- App Sandbox's default file-read scope does not cover `/opt/homebrew`, so a
  sandboxed process cannot open the dylib to link it at launch.

This deviation is scoped to this app. The standalone CLI runs under the Seatbelt
profile `CTask4PDF/sandbox/nullmark-cli.sb` instead. Neither setting is
re-enabled until the dylib is Apple-signed or vendored.

## Network behaviour

Everything runs on the local machine. The app makes no network request and ships
no remote script, font or telemetry.
[SECURITY.md](SECURITY.md#network-behaviour) states the same.

## Development

`mise.toml` pins the tool versions. Run the gates with:

```sh
just install
just check
```

`just check` runs every gate and stops at the first failure. `just ci-check`
runs `just install`, then the gates; the CI workflow runs it. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the commit and review rules and
[tests/README.md](tests/README.md) for the test suite.

## Documentation

- [docs/design.md](docs/design.md): replacement behaviour, scrubbed surfaces,
  verification scan, layout, MuPDF dependency and known limitations.
- [docs/README.md](docs/README.md): index of documents and the fact each owns.
- [tests/README.md](tests/README.md): test prerequisites, fixtures and cases.
- [SECURITY.md](SECURITY.md): vulnerability reporting, scope and network
  behaviour.
- [CONTRIBUTING.md](CONTRIBUTING.md): development workflow.
- [MAINTAINERS.md](MAINTAINERS.md): maintainers and succession.
- [AGENTS.md](AGENTS.md): rules for automated contributors.

## License

[MIT](LICENSE). [NOTICE](NOTICE) records third-party notices.

MuPDF is licensed under the AGPL
([Artifex licensing](https://artifex.com/licensing)). Distributing this app
beyond personal use requires either releasing the app's source under the AGPL or
holding a MuPDF commercial licence.
