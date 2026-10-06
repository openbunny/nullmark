# Nullmark

A local macOS app that removes a target string from a PDF and verifies its
absence across every surface. It exists to remove a deadname from a person's
own documents after a legal name change: the old text is removed from the page
and from the document metadata, and the new text is drawn or substituted in its
place. The output has no second `%%EOF`, no `/Prev` and no MuPDF version
string; it keeps the versionless `% Written by MuPDF` comment that the save
writes. Only occurrences of the target change; every other field keeps the
content it had. That is a field-level guarantee, not whole-file byte identity —
see "What preservation means at the byte level" below.

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
UTF-16BE) are covered; the XMP packet is scrubbed for the UTF-8, UTF-16BE and
UTF-16LE encodings of the name. A value that does not contain the target is
written back with the content it had, on every scrubbed surface.

## What preservation means at the byte level

`t4_replace` saves through `pdf_save_document` with garbage collection and
recompression on: a full, non-incremental rewrite that renumbers every object
in the file and recompresses untouched streams. The output is not a
byte-for-byte copy of the input with only the target's occurrences changed —
object numbers, the xref layout and stream encodings can all differ even where
no scrubbing touched that content.

What the tool guarantees is field-level: every non-target value keeps the
content it had, nothing is dropped or altered, and only occurrences of the
target change. For a file whose target lives only in the page text, four
fields are also asserted byte-identical between input and output by
`test_replace_preserves_metadata` in `tests/test_redactor.py`: the header
version line, the Info dictionary (compared with whitespace normalized by
`pdfutil.normalize_ws`), the XMP metadata stream payload, and both `/ID` array
elements. Nothing beyond those four is claimed to be byte-identical, and the
comparison runs on `mutool clean -d` output rather than the CLI's raw bytes,
because the raw file's object numbering and compression differ from the
input's.

After writing, an independent scan reopens the output and searches every
surface for the target: page text through `fz_stext`; every string's and
name's decoded text; every content, object-graph and embedded-file stream's
decompressed bytes in the target's UTF-8, UTF-16BE and UTF-16LE encodings;
every ToUnicode CMap that maps exactly the target's characters; and every
annotation appearance stream drawn through a CID font with no Unicode mapping.
The scan does not reuse the page-text extraction alone, so it sees a name
hidden in `/ActualText`, an optional-content group or metadata that page
extraction would miss. If the target survives on any surface, or a surface
cannot be read back, the output is deleted and a failure returned. A scan that
cannot run (the written file will not reopen or reparse) is also a failure.
The output is shippable only when the return code is 0 and the residual count
is 0.

Filesystem metadata (dates, permissions, extended attributes) is reapplied on
export; `FileMetadata.apply` also strips the `com.apple.quarantine` and
`com.apple.provenance` extended attributes the OS adds to the exported file, so
the export does not carry a record of the machine that produced it.

## Layout

- `CTask4PDF/` — the redaction core in C over MuPDF. `task4pdf.c` exposes one
  function, `t4_replace`, declared in `include/task4pdf.h`, which states every
  postcondition the caller relies on. It builds and runs as a standalone CLI
  with `-DT4_MAIN`.
- `App/Sources/` — the SwiftUI app. `PDFEngine` is the only code that calls
  `t4_replace`.
- `tests/` — the pytest suite for the C core, run against the CLI.
- `project.yml` — the `xcodegen` project. `Signing.xcconfig` builds ad-hoc
  signed with no team.

## Dependency

MuPDF, LLVM (clang-format, clang-tidy, LeakSanitizer, libFuzzer, llvm-cov) and
cppcheck are workstation prerequisites outside `mise.toml`; the justfile header
lists them.

`project.yml` links `-lmupdf` and searches `/opt/homebrew/{include,lib}`.
MuPDF is licensed under the AGPL
([Artifex licensing](https://artifex.com/licensing)): distributing this app
beyond personal use requires either releasing the app's source under the AGPL
or holding a MuPDF commercial licence.

### MuPDF upgrades

MuPDF parses attacker-supplied PDF input, so an upgrade changes the attack
surface. Review its security fixes before installing it.

## Sandbox and hardened runtime

The app does not adopt App Sandbox (no `com.apple.security.app-sandbox` in
`App.entitlements`) and disables the hardened runtime
(`ENABLE_HARDENED_RUNTIME` is `NO` in `project.yml`). Both are dropped for the
same root cause: `libmupdf.dylib` lives outside the bundle
(`/opt/homebrew/lib`), is neither Apple-signed nor vendored into it, and:

- the hardened runtime's library validation refuses to load a dylib not signed
  with the app's own Team ID;
- App Sandbox's default file-read scope does not cover `/opt/homebrew`, so a
  sandboxed process cannot open the dylib to link it at launch.

This deviation is scoped to this app only. The standalone CLI runs under the
Seatbelt profile `CTask4PDF/sandbox/nullmark-cli.sb` instead.

## Verification

`just test` runs the pytest suite. It asserts zero residual occurrences of the
target, the replacement present in the output text, the scrub of the Info
dictionary, XMP, outlines, annotations and form fields, a refusal to emit when
the target survives in an embedded file or an appearance stream, and the byte
identity of the four fields above. `tests/README.md` describes the fixtures and
the cases built on them.

The Swift app calls the C core through `PDFEngine.replace`, which
`EditorModel.apply()` calls. `PDFMetadata` is not on that path: it is a
read-only summary `EditorModel.load()` builds from the opened document for
display.

## Known limitations

- An embedded file (`/EmbeddedFiles`) is not rewritten: its format is
  arbitrary binary, and editing it blind risks corrupting it. The independent
  scan detects the target in an embedded file stream and fails closed, so a
  file that still contains the target in an attachment is refused.
  `T4Result.residual` (surfaced in the app as `PDFEngineError.residual`) counts
  the target across every surface, so a remaining occurrence anywhere reports
  a non-zero residual and a failure.
- An appearance stream that draws the target as its own content (a custom
  annotation or widget `/AP` that bakes in the text rather than deriving it
  from the field value) is not rewritten. The scan detects the target there
  and fails closed for the same reason as an embedded file.
- Text that is an image (a scan) has no text layer to remove and is out of
  scope. OCR is not performed.
- `FileMetadata.apply(to:)` removes the `com.apple.quarantine` and
  `com.apple.provenance` extended attributes with `removexattr` and returns a
  description of each removal the OS refuses, except for an absent attribute.
  APFS may keep projecting `com.apple.provenance` onto the exported file
  regardless of a successful call.

## Build

```sh
just install
just xctest
```

`just check` runs every gate and stops at the first failure.
