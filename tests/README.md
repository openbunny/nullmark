<!-- SPDX-License-Identifier: MIT -->

# Nullmark tests

Tests for `t4_replace` in `../CTask4PDF/task4pdf.c`, run against the standalone
`-DT4_MAIN` CLI, independent of the Xcode and Swift app.

## Contents

- [Prerequisites](#prerequisites)
- [Run](#run)
- [Oracles](#oracles)
- [Page-text fixtures](#page-text-fixtures)
- [Metadata and preservation](#metadata-and-preservation)
- [Non-page surface fixtures](#non-page-surface-fixtures)
- [Property-based tests](#property-based-tests)
- [Further coverage](#further-coverage)
- [Placement regression](#placement-regression)

## Prerequisites

MuPDF must be installed as a workstation tool, with its headers, library and
`mutool` available.

The CMake build in `../CMakeLists.txt` compiles the CLI against MuPDF with the
hardened flags and `-Werror`, and the CTest entry `pytest` passes its path to
the suite as `NULLMARK_CLI`. Run outside `just test` with that variable unset,
the suite fails rather than skips. `mutool` must be on `PATH`.

Python dependencies (pytest, hypothesis, fontTools, pikepdf, mypy) are pinned in
`pyproject.toml` and `uv.lock`. `just install` syncs them into `tests/.venv`,
and the justfile recipes run through `uv run`, so that environment is the one in
effect. Nothing needs a `pip install`.

`fixtures/generate.py` writes PDF bytes directly rather than through a PDF
library: most fixtures are malformed on purpose (NUL bytes in names, a bare
reference object, a reference cycle, trailer junk, an incremental update), and a
library either refuses to write those constructs or repairs them.

`fixtures/generate.py` imports `fontTools` at module level, and its CID-font
fixture builds a minimal TrueType font from scratch, so that fixture depends on
no installed font. Every fixture is deterministic: each generated PDF carries
the fixed `/ID` `FIXTURE_ID`.

## Run

```sh
just test
```

`just test` builds the CLI through the `dev` CMake preset, then runs the suite
through CTest. Each run generates the fixture PDFs into a pytest temp directory.
No test reads a committed binary fixture.

The suite asserts zero residual occurrences of the target, the replacement
present in the output text, the scrub of the Info dictionary, XMP, outlines,
annotations and form fields, a refusal to emit when the target survives in an
embedded file or an appearance stream, and the byte identity of the four fields
described under [Metadata and preservation](#metadata-and-preservation).

## Oracles

Assertions read the CLI's reported `T4Result` fields (`rc`, `matches`,
`residual`) directly and check the surfaces independently through `mutool`, so
neither oracle stands alone.

## Page-text fixtures

`test_redactor.py` runs `OLDNAME` -> `NEWNAME` through the CLI on generated PDFs
(`fixtures/generate.py`, standard library plus `fontTools`).

Three fixtures place the target in the page text:

- `simple.pdf`: one page, a literal string in base-14 Helvetica.
- `multipage.pdf`: three pages, the target on each.
- `cidfont.pdf`: one page, the target drawn with a from-scratch, embedded
  TrueType/CID (Identity-H) font that only contains glyphs for `OLDNAME`'s own
  letters. `NEWNAME` needs a `W` the font does not have, so this exercises the
  fallback-font path of `draw_replacement`.

`hidden_cid_annot.pdf` places the target only in a Hidden annotation's
appearance stream, drawn through a CID font with no `/ToUnicode`. Neither
`fz_stext` (blind to Hidden layers) nor a Unicode-driven reader can recover this
text, so it must fail closed rather than ship intact. It is subset from the
system TrueType font `generate.SYSTEM_TTF` names, and its test is skipped when
that font is missing or lacks the target's glyphs.

## Metadata and preservation

`test_replace_preserves_metadata` asserts for each page-text fixture:

- the target does not appear in `mutool convert -F text` output of the redacted
  file (the zero-residual requirement);
- the replacement does appear there;
- for the two non-CID fixtures, the target is also absent from the trailer, from
  every object as `pikepdf` serializes it, and from every stream after
  `pikepdf` decodes its filters, and absent from the CLI's raw output. The CID
  fixture's original run is hex-coded CID data, not literal ASCII, so a
  literal-byte search there would test nothing;
- the output has exactly one `%%EOF` and no `/Prev`, checked on the CLI's own
  raw output and not on a re-saved copy;
- the raw output does not match a `MuPDF <digit>` version-string pattern
  (case-insensitive). MuPDF's save always stamps a versionless
  `% Written by MuPDF` product comment that the save API used here cannot
  suppress, so the check rejects only the version-number form, not that comment;
- the PDF header version (`pikepdf.Pdf.pdf_version`), the Info dictionary
  (its values as `unparse()` bytes, which `qpdf` writes with sorted keys, and
  its key order and serialization as `mutool show -g` prints them), the decoded
  XMP packet (`read_bytes()`), and both `/ID` array elements (raw bytes) are
  unchanged from the input. Both files are read directly, not re-saved first.

These four fields are the only ones checked for byte identity. The CLI's save
path is a full, non-incremental rewrite that renumbers every object and
recompresses untouched streams, so the raw output is not byte-identical to the
input as a whole even when these fixtures carry the target only in the page
text. The claim is stated in
[README.md](../README.md#what-preservation-means-at-the-byte-level).

The raw CLI output contains a `% Written by MuPDF` comment after the header
(from `pdf_save_document`; `wopts.reproducible = 1` suppresses the version
number but not the product name). The version-string assertion rejects only a
`MuPDF <digit>` pattern, not the comment itself, which matches the README claim
of no engine version string.

## Non-page surface fixtures

Each of these fixtures places the target on exactly one non-page surface, to
prove the scrub reaches it and the verification catches what is not scrubbed:

- `info.pdf`: the target in Info `/Author`, `/Subject`, `/Keywords` and a custom
  `/DeadName` key (with `/Title`, `/Creator`, `/Producer` benign).
- `xmp.pdf`: the target in the XMP `dc:title`.
- `outline.pdf`: the target in an outline (bookmark) `/Title`.
- `annotation.pdf`: the target in a `Text` annotation `/Contents` and `/T`.
- `field.pdf`: the target in an AcroForm text field `/V` and `/DV`
  (`/NeedAppearances true`, no baked appearance stream).
- `embedded.pdf`: the target inside an embedded file stream.
- `name_value.pdf`: the target as a PDF Name (not String) value, a custom
  `/ClientRef` entry in the Info dictionary.
- `embedded_utf16le.pdf`: the target inside an embedded file stream, encoded
  only as UTF-16LE, with nothing preceding it in the stream, so no accidental
  UTF-16BE- or UTF-8-shaped byte run stands in for it.
  `test_utf16le_embedded_target_fails_closed` asserts the fixture carries
  neither.

`test_scrub_removes_target_from_surface` runs every fixture above except
`embedded.pdf` and `embedded_utf16le.pdf`, and also runs `objstm.pdf` from
[Further coverage](#further-coverage). It asserts that the CLI reports `rc=0`,
`residual=0` and `matches>=1`, that an independent `pikepdf` read of the output
(every object and decoded stream, and the raw bytes) contains the replacement
and not the target, and
that an unrelated metadata marker on the same fixture survives unchanged. It
also confirms the input fixture did carry the target, so a scrub that did
nothing fails the test instead of passing it. `name_value.pdf` runs through this
same check, which proves the Name-value scrub replaces the target and does not
leave `residual` at 0 by skipping the scan of it.

`test_embedded_file_target_fails_closed` and
`test_utf16le_embedded_target_fails_closed` assert that an embedded file bearing
the target (UTF-8 or Latin-1, and UTF-16LE, respectively) makes the CLI exit
non-zero with `residual>=1` and produce no output file. That is the fail-closed
contract for a surface that is not rewritten.

`test_hidden_cid_annotation_fails_closed` asserts the same contract for
`hidden_cid_annot.pdf`: a surface this tool can neither redact (annotation
appearance streams are not rewritten) nor prove clean (no Unicode mapping to
read the glyphs back) must not ship.

## Property-based tests

`test_redactor_hypothesis.py` widens the two oracles (redaction completeness,
non-target byte preservation) past the hand-picked cases of `test_redactor.py`
with Hypothesis-generated fixtures, read the same way through `pikepdf`:

- `test_scrub_completeness_and_preservation_across_surfaces` draws a target
  (arbitrary Unicode, or a run of PDF-syntax metacharacters), an unrelated
  marker, a non-empty subset of `{info, xmp, outline, annotation, field}`, and
  an occurrence count, through `build_combo` in `fixtures/generate.py`.
  `build_combo` places `occurrences` non-adjacent copies of the target on every
  chosen surface at once, a case the hand-picked single-surface fixtures do not
  cover. Checks are scoped to decoded string values (every string in the
  object graph, including object streams, and every string operand of the
  page, form XObject, pattern and Type 3 glyph content streams, plus the XMP
  stream's own UTF-8-decoded payload for the xmp surface), not a raw substring
  search over decoded bytes. The raw search is unsound both ways once the
  target can be any Unicode text or metacharacter: it can miss a target
  present only in hex-encoded form, and it can flag ordinary PDF structure
  that coincides with a short target by chance. A target already present in
  the fixture's own fixed non-target bytes (the page text of `BENIGN_BODY`, or
  the XMP template's own markup when xmp is chosen) is skipped. On that input
  the residual check in `task4pdf.c`, a raw byte scan over non-structural
  stream data and not only parsed PDF strings, reports a residual and fails
  closed, which is correct and irrelevant to the property.
- `test_empty_target_fails_closed` and
  `test_empty_target_against_page_text_fixtures_fails_closed` assert the
  empty-target case is a fail-closed input error (`rc=1`, an explanatory
  `error`, no output file), not a no-op: `t4_replace` rejects a zero-length find
  string before opening the document.

## Further coverage

- `objstm.pdf`: the `info` fixture rewritten by `mutool clean -Z` into a
  compressed object stream (ObjStm) indexed by a compressed cross-reference
  stream, so the Info dictionary is reached only by resolving through that
  compression and not through a classic xref table.
- `appearance.pdf`: a FreeText annotation whose `/AP /N` appearance stream draws
  the target as baked content. `task4pdf.c` never rewrites appearance streams;
  `test_appearance_stream_target_fails_closed` asserts the CLI relies on
  `verify_residual` alone here and still fails closed (`rc != 0`,
  `residual >= 1`, no output file).
- `test_incremental_update_remnants_dropped` builds inline, not from the
  `generate.py` fixture set, a base revision whose Info carries the target,
  followed by a real incremental-update section (`/Prev`) that supersedes it
  with a clean value. It asserts the CLI's output, a full non-incremental
  rewrite, drops the stale revision's raw bytes and does not only leave them out
  of the residual count.
- `test_scrub_removes_astral_target` runs the XMP and Info surfaces with a
  target containing a non-BMP codepoint, to exercise the surrogate-pair branch
  of `encode_utf16be`. Every other test's target is pure ASCII or BMP.
- `test_cli_rejects_empty_target` and `test_cli_rejects_oversized_target` assert
  that the CLI's two input-validation error paths (an empty find string, and one
  over `MAX_NEEDLE` codepoints) fail closed with the expected error text and no
  output file.
- `test_bare_reference_to_dict_is_resolved_and_scrubbed` builds an object whose
  whole body is a reference to the Info dictionary and asserts the output holds
  a scrubbed copy of that dictionary in its place.
  `test_bare_reference_without_copyable_value_fails_closed` asserts the same
  construct pointing at a stream, or at a reference cycle, is refused with no
  output file.
- `test_scrub_kitchen_sink_all_surfaces` runs one fixture that carries the
  target on every surface at once (page text, Info, XMP, outline, annotation,
  field), to catch a cross-surface regression that a fixture touching one
  surface at a time can miss.
- `test_deep_nesting_fails_closed` builds directly nested structure past the
  container depth cap and asserts the CLI fails closed with no output file
  instead of recursing without limit.
- `test_oversized_stream_fails_closed` builds an XMP stream that decompresses
  past the size cap and asserts the CLI fails closed with no output file.
- `test_nul_truncated_string_fails_closed` builds an Info string value with an
  embedded NUL byte before the target and asserts the CLI refuses it, naming a
  string value, with no output file.
- `test_nul_escaped_name_scrubs_clean` builds an Info Name value with an escaped
  NUL (`#00`) before the target and asserts the target is absent from the raw
  output and the replacement present.
- `test_xref_stream_id_with_nul_byte_scrubs_clean` pins a trailer `/ID` digest
  that contains a NUL byte, converts the file to a compressed cross-reference
  stream with `mutool clean -Z`, and asserts the output scrubs the target and
  preserves the digest.
- `test_unterminated_trailer_id_fails_closed` runs the committed corpus seed
  `CTask4PDF/fuzz/corpus/unterminated-id.pdf` and asserts the CLI refuses it
  with `rc=1`, naming the trailer `/ID`, with no output file.
- `test_trailer_junk_scrubs_clean` places the target in a `/Junk` dictionary in
  the trailer and asserts the output holds neither the target nor the `/Junk`
  entry.
- `test_key_bearing_target_fails_closed` places the target inside a dictionary
  key (`/Client` followed by the target) and asserts the CLI exits non-zero with
  `residual>=1` and no output file.
- `test_cli_redacts_under_its_sandbox_profile` runs the CLI through
  `sandbox-exec` with `CTask4PDF/sandbox/nullmark-cli.sb` and asserts `rc=0`,
  `residual=0` and an output file.
- `test_cidfont_fixture_builds_without_any_installed_font` builds the CID-font
  fixture with every `Path.exists` call patched to return false and asserts the
  file is written.

## Placement regression

`pdf_set_annot_rect` receives the stext-derived quad directly, with no
`fz_transform_quad` and no manual inverse-matrix step first.
`pdf_set_annot_rect` already applies the inverse page transform, so transforming
the quad a second time places the redaction away from the text for any run not
near the vertical centre of the page. The `simple` and `multipage` fixtures draw
their text at y=700 on a 792 pt page, far from the centre, so
`test_replace_preserves_metadata` guards that placement.
