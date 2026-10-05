# Nullmark tests

Tests for `t4_replace` in `../CTask4PDF/task4pdf.c`, run against the standalone
`-DT4_MAIN` CLI, independent of the Xcode/Swift app.

## Prerequisite

MuPDF must be installed as a workstation tool, with its headers,
library, and `mutool` available.

The suite builds the CLI against MuPDF under `/opt/homebrew` with the
hardened flags and `-Werror` (`conftest.py`), and needs `cc` and `mutool` on
`PATH`. A missing MuPDF fails the build; the suite never skips it.

Python dependencies (pytest, hypothesis, fontTools, mypy) are pinned in
`pyproject.toml`/`uv.lock`. `just install` syncs them into `tests/.venv`, and
the justfile recipes run through `uv run` so that environment is the one in
effect; nothing needs a `pip install`.

`fixtures/generate.py` imports `fontTools` at module level, and its CID-font
fixture builds a minimal TrueType font from scratch, so that fixture depends on
no installed font. Every fixture is deterministic: each generated PDF carries
the fixed `/ID` `FIXTURE_ID`.

## Run

```sh
just test
```

Each test run builds the CLI once per session (`cc -DT4_MAIN ...`, with the
search paths and library `project.yml` declares) and generates the fixture
PDFs into a pytest temp directory; no test here reads a committed binary
fixture.

## What's tested

`test_redactor.py` runs `OLDNAME` -> `NEWNAME` through the CLI on generated
PDFs (`fixtures/generate.py`, stdlib plus `fontTools`).

Three fixtures place the target in the page text:

- `simple.pdf` — one page, a literal string in base-14 Helvetica.
- `multipage.pdf` — three pages, the target on each.
- `cidfont.pdf` — one page, the target drawn with a from-scratch, embedded
  TrueType/CID (Identity-H) font that only contains glyphs for `OLDNAME`'s
  own letters. Since `NEWNAME` needs a `W` the font doesn't have, this
  exercises `draw_replacement`'s fallback-font path.

`hidden_cid_annot.pdf` places the target only in a Hidden annotation's
appearance stream, drawn through a CID font with no `/ToUnicode`: neither
`fz_stext` (blind to Hidden layers) nor a Unicode-driven reader can recover
this text, so it must fail closed rather than ship silently intact. It is
subset from the system TrueType font `generate.SYSTEM_TTF` names, and its test
is skipped when that font is missing or lacks the target's glyphs.

`test_replace_preserves_metadata` asserts for each:

- the target does not appear in `mutool convert -F text` output of the
  redacted file (the zero-residual requirement);
- the replacement does appear there;
- for the two non-CID fixtures, the target is also absent from the raw,
  `mutool clean -d`-decompressed content stream (the CID fixture's original
  run is hex-coded CID data, not literal ASCII, so a literal-byte search
  there would test nothing);
- the output has exactly one `%%EOF` and no `/Prev`, checked on the CLI's own
  raw output (not a `mutool clean` copy — `mutool clean` stamps its own
  `% Written by MuPDF ...` comment, which would make a same-copy check of the
  producer string below a false positive regardless of what the CLI wrote);
- the raw output does not match a `MuPDF <digit>` version-string pattern
  (case-insensitive); MuPDF's save always stamps a versionless
  `% Written by MuPDF` product comment that the save API used here cannot
  suppress, so the check rejects only the version-number form, not that
  comment;
- the PDF header version line, the Info dictionary (whitespace-normalized,
  `pdfutil.normalize_ws`), the XMP packet, and both `/ID` array elements are
  unchanged from the input, compared after running both the input and the
  output through `mutool clean -d` (`pdfutil.py` parses the resulting classic
  (non-object-stream) PDF text with small regexes — it does not attempt to be
  a general PDF parser). These are the only four fields checked for byte
  identity; the CLI's save path is a full, non-incremental rewrite that
  renumbers every object and recompresses untouched streams, so the raw
  output is not byte-identical to the input as a whole even when these
  fixtures carry the target only in the page text — only these four fields
  are asserted to come out unchanged.

The following fixtures each place the target on exactly one non-page surface,
to prove the scrub reaches it and the verification catches what is not
scrubbed:

- `info.pdf` — the target in Info `/Author`, `/Subject`, `/Keywords` and a
  custom `/DeadName` key (with `/Title`, `/Creator`, `/Producer` benign).
- `xmp.pdf` — the target in the XMP `dc:title`.
- `outline.pdf` — the target in an outline (bookmark) `/Title`.
- `annotation.pdf` — the target in a `Text` annotation `/Contents` and `/T`.
- `field.pdf` — the target in an AcroForm text field `/V` and `/DV`
  (`/NeedAppearances true`, no baked appearance stream).
- `embedded.pdf` — the target inside an embedded file stream.
- `name_value.pdf` — the target as a PDF Name (not String) value, a custom
  `/ClientRef` entry in the Info dict.
- `embedded_utf16le.pdf` — the target inside an embedded file stream, encoded
  only as UTF-16LE, with nothing preceding it in the stream, so no accidental
  UTF-16BE- or UTF-8-shaped byte run stands in for it;
  `test_utf16le_embedded_target_fails_closed` asserts the fixture carries
  neither.

`test_scrub_removes_target_from_surface` (all but `embedded.pdf` and
`embedded_utf16le.pdf`) asserts the CLI reports `rc=0`, `residual=0` and
`matches>=1`, that an independent `mutool clean -d` decompression of the
output contains the replacement and not the target, and that an unrelated
metadata marker on the same fixture survives unchanged. It also confirms the
input fixture did carry the target, so a scrub that silently did nothing would
fail the test rather than pass it. `name_value.pdf` runs through this same
check, proving the Name-value scrub replaces the target rather than
merely leaving `residual` at 0 by not scanning it.

`test_embedded_file_target_fails_closed` and
`test_utf16le_embedded_target_fails_closed` assert that an embedded file
bearing the target (UTF-8/Latin-1 and UTF-16LE respectively) makes the CLI
exit non-zero with `residual>=1` and produce no output file — the fail-closed
contract for a surface that is not rewritten.

`test_hidden_cid_annotation_fails_closed` asserts the same fail-closed
contract for `hidden_cid_annot.pdf`: a surface this tool can neither redact
(annotation appearance streams are not rewritten) nor prove clean (no
Unicode mapping to read the glyphs back) must not ship.

Assertions read the CLI's reported `T4Result` fields (`rc`, `matches`,
`residual`) directly and check the surfaces independently through `mutool`, so
neither oracle stands alone.

`test_redactor_hypothesis.py` widens the same two oracles (redaction
completeness, non-target byte preservation) past `test_redactor.py`'s
hand-picked cases with Hypothesis-generated fixtures, composed the same way
through `pdfutil.py`:

- `test_scrub_completeness_and_preservation_across_surfaces` draws a target
  (arbitrary Unicode, or a run of PDF-syntax metacharacters), an unrelated
  marker, a non-empty subset of `{info, xmp, outline, annotation, field}`, and
  an occurrence count, via `fixtures/generate.py`'s `build_combo`, which places
  `occurrences` non-adjacent copies of the target on every chosen surface at
  once (a case the hand-picked single-surface fixtures above don't cover).
  Checks are scoped to decoded string values (`pdfutil.string_values`, plus
  the XMP stream's own UTF-8-decoded payload for the xmp surface), not a raw
  substring search over `mutool clean -d` text: the latter is unsound both
  ways once the target can be any Unicode text or metacharacter — it can miss
  a target present only in hex-encoded form, and it can flag ordinary PDF
  structure that coincides with a short target by chance. A target already
  present in the fixture's own fixed non-target bytes (`BENIGN_BODY`'s page
  text; the XMP template's own markup, when xmp is chosen) is skipped: on
  that input, task4pdf.c's own residual check — a raw byte scan over
  non-structural stream data, not only parsed PDF strings — correctly, but
  irrelevantly, reports a residual and fails closed.
- `test_empty_target_fails_closed` and
  `test_empty_target_against_page_text_fixtures_fails_closed` assert the
  empty-target case is a fail-closed input error (`rc=1`, an explanatory
  `error`, no output file), not a no-op: `t4_replace` rejects a zero-length
  find string before opening the document.

Further coverage beyond the surfaces above:

- `objstm.pdf` — the `info` fixture rewritten by `mutool clean -Z` into a
  compressed object stream (ObjStm) indexed by a compressed cross-reference
  stream, so the Info dict is reached only by resolving through that
  compression rather than a classic xref table.
- `appearance.pdf` — a FreeText annotation whose `/AP /N` appearance stream
  draws the target as baked content. `task4pdf.c` never rewrites appearance
  streams; `test_appearance_stream_target_fails_closed` asserts the CLI
  relies on `verify_residual` alone here and still fails closed (`rc != 0`,
  `residual >= 1`, no output file).
- `test_incremental_update_remnants_dropped` builds (not via `generate.py`'s
  fixture set, inline in the test) a base revision whose Info carries the
  target, followed by a real incremental-update section (`/Prev`) that
  supersedes it with a clean value, and asserts the CLI's output — a full,
  non-incremental rewrite — drops the stale revision's raw bytes rather than
  only leaving them out of the residual count.
- `test_scrub_removes_astral_target` runs the XMP and Info surfaces with a
  target containing a non-BMP codepoint, to exercise `encode_utf16be`'s
  surrogate-pair branch (every other test's target is pure ASCII/BMP).
- `test_cli_rejects_empty_target` / `test_cli_rejects_oversized_target` assert
  the CLI's two input-validation error paths (an empty find string, one over
  `MAX_NEEDLE` codepoints) fail closed with the expected error text and no
  output file.
- `test_scrub_kitchen_sink_all_surfaces` runs one fixture that carries the
  target on every surface at once (page text, Info, XMP, outline, annotation,
  field), to catch a cross-surface regression that a fixture touching only
  one surface at a time could miss.

## Placement regression

`pdf_set_annot_rect` receives the stext-derived quad directly, with no
`fz_transform_quad` and no manual inverse-matrix step first:
`pdf_set_annot_rect` already applies the inverse page transform, so
transforming the quad a second time places the redaction away from the text
for any run not near the vertical centre of the page.
The `simple` and `multipage` fixtures draw their text at y=700 on a 792 pt
page, far from the centre, so `test_replace_preserves_metadata` guards that
placement.

The raw CLI output contains a `% Written by MuPDF` comment after the header
(from `pdf_save_document`; `wopts.reproducible = 1` suppresses the version
number but not the product name). The version-string assertion above rejects
only a `MuPDF <digit>` pattern, not the comment itself, matching `README.md`'s
claim ("no engine version string").
