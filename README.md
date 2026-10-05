# Nullmark

A local macOS app that removes a target string from a PDF and verifies its
absence across every surface. Its purpose is to let someone remove a deadname
from their own documents after a legal name change: the old text is removed
from the page and from the document metadata, the new text is drawn or
substituted in its place, and the output carries no record that a rewrite tool
touched the file — no second `%%EOF`, no `/Prev`, no engine version string.
Only occurrences of the target change; every other field keeps the same
content it had. That is a field-level guarantee, not whole-file byte
identity — see "What preservation means at the byte level" below.

Everything runs on the local machine. The app makes no network request.

## What replacement means here

The old string is removed from the page content stream, not covered. After a
replacement, the old string does not appear in the output's text, in a search,
or in the decompressed content bytes. The replacement is drawn as vector text
in the run's own font, size, colour and position; where that font lacks a
glyph for the new text, a fallback font is embedded so the character still
renders.

The target is also scrubbed from the document's non-page surfaces: the Info
dictionary values (`/Title`, `/Author`, `/Subject`, `/Keywords`, `/Creator`,
`/Producer` and any custom key), the XMP metadata packet, outline (bookmark)
titles, annotation text (`/Contents`, `/T`), and form-field values (`/V`,
`/DV`). String values are decoded and re-encoded, so both PDF string forms
(literal `()` and hex `<>`) and both text encodings (PDFDocEncoding and
UTF-16BE) are handled; the XMP packet is scrubbed for a UTF-8 and a UTF-16BE
encoding of the name. A value that does not contain the target is written
back with the same content it had, not a different one, on every scrubbed
surface. Four of those fields — the Info dictionary, the XMP packet, both
`/ID` elements and the header version — also come out byte-for-byte identical
for a file whose target lives only in the page text, and the test suite
asserts exactly that (`tests/test_redactor.py:137,144-155`). Byte identity for
the rest (outlines, annotations, form fields) is not asserted or guaranteed;
see "What preservation means at the byte level" below.

## What preservation means at the byte level

`t4_replace` saves through `pdf_save_document` with `do_garbage=3` and
`do_compress=1` (`CTask4PDF/task4pdf.c:740-742`): a full, non-incremental
rewrite that garbage-collects and renumbers every object in the file and
recompresses untouched streams. The output is not a byte-for-byte copy of the
input with only the target's occurrences changed — object numbers, the xref
layout and stream encodings can all differ even where no scrubbing touched
that content.

What the tool guarantees is field-level: every non-target value keeps the
same content it had, nothing is dropped or altered, and only occurrences of
the target change. Four fields are additionally asserted byte-identical
between input and output, because the save path happens not to disturb them
and the test suite checks it directly (`tests/test_redactor.py:137,
144-155`): the header version line, the Info dictionary (compared with
whitespace normalized, `tests/pdfutil.py:97-98`), the XMP metadata stream
payload, and both `/ID` array elements. Nothing beyond those four is claimed
to be byte-identical, and the comparison runs on `mutool clean -d` output
rather than the CLI's raw bytes, because the raw file's object numbering and
compression are expected to differ from the input's.

After writing, an independent scan reopens the output and searches every
surface for the target: page text through `fz_stext`, and every string's
decoded text plus every content, object-graph and embedded-file stream's
decompressed bytes in the target's UTF-8 and UTF-16BE encodings. This scan does
not reuse only the page-text extraction, so it sees a name hidden in
`/ActualText`, an optional-content group or metadata that page extraction would
miss. If the target survives on any surface — including inside an embedded file,
whose arbitrary binary format is out of scope to rewrite safely — the output is
deleted and a non-zero result returned rather than shipping a file that still
contains it. A scan that cannot run (the written file will not reopen or
reparse) is also a failure, never a silent pass. The output is shippable only
when the return code is 0 and the residual count is 0, which now means the
target is absent from every surface.

Filesystem metadata (dates, permissions, extended attributes) is reapplied on
export; `FileMetadata.apply` also strips the `com.apple.quarantine` and
`com.apple.provenance` extended attributes the OS adds to the exported file, so
the export does not carry a record of the machine that produced it.

## Layout

- `CTask4PDF/` — the redaction core in C over MuPDF. `task4pdf.c` exposes one
  function, `t4_replace`, declared in `include/task4pdf.h`. It builds and runs
  as a standalone CLI with `-DT4_MAIN` for iteration without Xcode.
- `App/Sources/` — the SwiftUI app: `NullmarkApp`, `ContentView`, `EditorModel`,
  `FileMetadata`.
- `project.yml` — the `xcodegen` project. `Signing.xcconfig` builds ad-hoc
  signed with no team.

## Dependency

MuPDF is required and provided by Homebrew:

```sh
brew install mupdf
```

`project.yml` links `-lmupdf` and searches `/opt/homebrew/{include,lib}`.
MuPDF is AGPL: distributing this app beyond personal use requires either
releasing the app's source under the AGPL or holding a MuPDF commercial
licence.

### MuPDF version pin

A Homebrew dependency is normally named by its install command, not a
transcribed version, because a written number goes stale silently and
Renovate does not track Homebrew formulae. This dependency is the deliberate
exception: MuPDF parses attacker-supplied PDF input, so an unreviewed
Homebrew upgrade — pulling in a MuPDF version whose own CVE fixes or
regressions were never looked at — is exactly the exposure nullmark exists to
avoid introducing elsewhere. `CTask4PDF/mupdf.lock` records the Homebrew
`mupdf` version and the sha256 of the resolved `libmupdf.dylib` the last
reviewed build linked; `just mupdf-verify` (wired into `just check`) fails
the gate if the linked library's version or hash has since drifted.

A fresh checkout with no `mupdf.lock` yet is not blocked: `mupdf-verify`
prints a notice and passes. After reviewing a MuPDF upgrade for its CVE
delta, move the pin forward with:

```sh
just mupdf-lock
```

## Sandbox and hardened runtime

The app does not adopt App Sandbox (no `com.apple.security.app-sandbox` in
`App.entitlements`) and disables the hardened runtime
(`ENABLE_HARDENED_RUNTIME: NO` in `project.yml`). Both are dropped for the same
root cause: `libmupdf.dylib` comes from Homebrew (`/opt/homebrew/lib`), is
neither Apple-signed nor vendored into the bundle, and:

- the hardened runtime's library validation refuses to load a dylib not signed
  with the app's own Team ID;
- App Sandbox's default file-read scope does not cover `/opt/homebrew`, so a
  sandboxed process cannot open the dylib to link it at launch.

This deviation is scoped to this app only.

## Current state

The C core is proven from the CLI: on matrix-scaled and text-matrix PDFs it
removes the target (`just test` runs `pytest tests -v` and
`CTask4PDF/verify-redaction.sh`, both asserting zero residual occurrences),
places the replacement in the original font and size, scrubs the target from
the Info dictionary, XMP, outlines, annotations and form fields, refuses to
emit when the target survives in an embedded file, and preserves every
non-target field's content — byte-identical for the Info dictionary, XMP,
both `/ID` elements and the header version (see "What preservation means at
the byte level" above), semantically unchanged elsewhere.

The Swift app calls the C core directly: `PDFEngine.swift` wraps `t4_replace`
(`PDFEngineError`, `PDFReplacementResult`), and `EditorModel.apply()` calls
`PDFEngine.replace`. `PDFMetadata` is unrelated to that path — it is a
read-only struct `EditorModel.load()` builds from the opened document to
display the Info dictionary and document section in `ContentView`. The app
target builds: `just build`
(`xcodegen generate` then `xcodebuild build -project Nullmark.xcodeproj -scheme
Nullmark CODE_SIGNING_ALLOWED=NO`).

## Known limitations

- An embedded file (`/EmbeddedFiles`) is not rewritten: its format is
  arbitrary binary, and editing it blind risks corrupting it. The independent
  scan instead detects the target in an embedded file stream and fails closed,
  so a file that still contains the target in an attachment is refused, never
  shipped. `T4Result.residual` (surfaced in the app as
  `PDFEngineError.residual`) counts the target across every surface — page
  text, metadata and streams — so a remaining occurrence anywhere reports
  non-zero residual and failure.
- An appearance stream that draws the target as its own content (a custom
  annotation or widget `/AP` that bakes in the text rather than deriving it
  from the field value) is not rewritten. The scan detects the target there
  and fails closed for the same reason as an embedded file.
- Text that is an image (a scan) has no text layer to remove and is out of
  scope until OCR or region redaction is added.
- `FileMetadata.apply(to:)` removes the `com.apple.provenance` extended
  attribute with `removexattr`, which reports success, but APFS may keep
  projecting the attribute onto the exported file regardless.

## Build

```sh
xcodegen generate
xcodebuild -project Nullmark.xcodeproj -scheme Nullmark build
```

`just check` runs every gate and reports every failure together.
