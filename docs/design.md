<!-- SPDX-License-Identifier: MIT -->

# Design

How `nullmark` replaces and verifies a target string, what it covers, and what
it refuses.

## Contents

- [Layout](#layout)
- [Replacement and scrubbed surfaces](#replacement-and-scrubbed-surfaces)
- [Verification scan](#verification-scan)
- [MuPDF dependency](#mupdf-dependency)
- [Known limitations](#known-limitations)

## Layout

- `CTask4PDF/`: the redaction core in C over MuPDF. `task4pdf.c` exposes one
  function, `t4_replace`, declared in `include/task4pdf.h`, which states every
  postcondition the caller relies on. It builds and runs as a standalone CLI
  with `-DT4_MAIN`.
- `App/Sources/`: the SwiftUI app. `PDFEngine` is the only code that calls
  `t4_replace`.
- `tests/`: the pytest suite for the C core, run against the CLI. See
  [tests/README.md](../tests/README.md).
- `CMakeLists.txt` and `CMakePresets.json`: the C build of the CLI, the fuzz
  target and the coverage runner, and the CTest entries for pytest and the
  fuzzer. `gcovr.cfg` configures the coverage report.
- `mupdf/`: the standalone CMake project and preset that build MuPDF once into
  `build/mupdf`. See [MuPDF dependency](#mupdf-dependency).
- `project.yml`: the `xcodegen` project. `Signing.xcconfig` builds ad-hoc signed
  with no team.

## Replacement and scrubbed surfaces

The replacement removes the old string from the page content stream. It does not
cover it. The replacement text is drawn as vector text in the run's own font,
size, colour and position. Where that font has no glyph for the new text, a
fallback font is embedded.

The target is also scrubbed from these non-page surfaces:

- the Info dictionary values (`/Title`, `/Author`, `/Subject`, `/Keywords`,
  `/Creator`, `/Producer` and any custom key);
- the XMP metadata packet;
- outline (bookmark) titles;
- annotation text (`/Contents`, `/T`);
- form-field values (`/V`, `/DV`).

String values are decoded and re-encoded, so both PDF string forms (literal `()`
and hex `<>`) and both text encodings (PDFDocEncoding and UTF-16BE) are covered.
The XMP packet is scrubbed for the UTF-8, UTF-16BE and UTF-16LE encodings of the
name. A value that does not contain the target is written back with the content
it had, on every scrubbed surface.

## Verification scan

After writing, an independent scan reopens the output and searches every surface
for the target:

- page text through `fz_stext`;
- every string's and name's decoded text;
- every content, object-graph and embedded-file stream's decompressed bytes, in
  the target's UTF-8, UTF-16BE and UTF-16LE encodings;
- every ToUnicode CMap that maps exactly the target's characters;
- every annotation appearance stream drawn through a CID font with no Unicode
  mapping.

The scan does not reuse the page-text extraction alone, so it sees a name hidden
in `/ActualText`, an optional-content group or metadata that page extraction
misses.

If the target survives on any surface, or a surface cannot be read back, the
output is deleted and a failure is returned. A scan that cannot run, because the
written file will not reopen or reparse, is also a failure. The output is usable
only when the return code is 0 and the residual count is 0. `T4Result.residual`
counts the target across every surface, and the app surfaces it as
`PDFEngineError.residual`.

The byte-identity claims and their limits are in
[README.md](../README.md#what-preservation-means-at-the-byte-level).

## MuPDF dependency

`mupdf/CMakeLists.txt` is a standalone CMake project with no language enabled.
It downloads the MuPDF source release it pins by URL and SHA-256 and builds
`libmupdf.a` and `libmupdf-third.a` with MuPDF's own Makefile on every logical
core, installing them with the headers and licence texts under `build/mupdf`.
`just mupdf` builds it; every recipe that links MuPDF depends on that recipe, so
a checkout builds MuPDF once. The root `CMakeLists.txt` and
`project.yml` link `build/mupdf`; the root project fails at configure time when
it is missing. So the app, the CLI, the test suite and the fuzz target run
the same MuPDF. LLVM (clang-format, clang-tidy,
LeakSanitizer, libFuzzer, llvm-cov) and cppcheck are workstation prerequisites
outside `mise.toml`; the `justfile` header lists them. The AGPL terms for distributing a linked build are in
[README.md](../README.md#license). The sandbox and hardened-runtime entitlements
are described in
[README.md](../README.md#sandbox-and-hardened-runtime).

MuPDF parses attacker-supplied PDF input, so an upgrade changes the attack
surface. Review its security fixes before changing the pin.

## Known limitations

- An embedded file (`/EmbeddedFiles`) is not rewritten: its format is arbitrary
  binary, and editing it blind risks corrupting it. The independent scan detects
  the target in an embedded file stream and fails closed, so a file that still
  contains the target in an attachment is refused. `T4Result.residual` counts
  the target across every surface, so a remaining occurrence anywhere reports a
  non-zero residual and a failure.
- An appearance stream that draws the target as its own content (a custom
  annotation or widget `/AP` that bakes in the text rather than deriving it from
  the field value) is not rewritten. The scan detects the target there and fails
  closed for the same reason as an embedded file.
- An object whose whole body is a reference to another object
  (`5 0 obj 4 0 R endobj`) is rewritten to hold a copy of the value the
  reference resolves to, so the scrub reaches it and MuPDF's save does not leak
  memory on it. Such an object that references a stream, or whose reference does
  not resolve to a value, is refused before anything is saved.
- Text that is an image (a scan) has no text layer to remove and is out of
  scope. OCR is not performed.
- `FileMetadata.apply(to:)` removes the `com.apple.quarantine` and
  `com.apple.provenance` extended attributes with `removexattr` and returns a
  description of each removal the OS refuses, except for an absent attribute.
  APFS may keep projecting `com.apple.provenance` onto the exported file
  regardless of a successful call.
