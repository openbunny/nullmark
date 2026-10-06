from __future__ import annotations

import re
import string
import tempfile
from itertools import chain
from pathlib import Path
from typing import TYPE_CHECKING, Final

import pikepdf
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from conftest import (
    REPLACEMENT,
    content_operands,
    direct,
    graph,
    id_pair,
    result_fields,
    run_cli,
    string_text,
)
from fixtures.generate import (
    BENIGN_BODY,
    COMBO_SURFACES,
    XMP_TEMPLATE,
    build_combo,
    generate_all,
)

if TYPE_CHECKING:
    import pytest

_BENIGN_STREAM_TEXT: Final = BENIGN_BODY.decode("latin-1")
_XMP_WRAPPER_TEXT: Final = XMP_TEMPLATE.format(title="")


def _string_values(doc: pikepdf.Pdf) -> list[str]:
    return [
        string_text(o)
        for o in chain(graph(doc), content_operands(doc))
        if isinstance(o, pikepdf.String)
    ]


def _name_values(doc: pikepdf.Pdf) -> list[str]:
    out: list[str] = []
    for obj in chain(graph(doc), direct(doc.trailer)):
        if isinstance(obj, pikepdf.Name):
            out.append(obj.unparse().decode("latin-1")[1:])
        elif isinstance(obj, pikepdf.Dictionary | pikepdf.Stream):
            keys = obj.keys()
            out.extend(pikepdf.Name(k).unparse().decode("latin-1")[1:] for k in keys)
    return out


_unicode_target: Final = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x10FFFF, exclude_categories=("Cs", "Cc")
    ),
    min_size=1,
    max_size=12,
)
_metachar_target: Final = st.text(alphabet="()\\<>[]{}%/#\r\n", min_size=1, max_size=6)
TARGET_STRATEGY: Final = st.one_of(_unicode_target, _metachar_target)
MARKER_STRATEGY: Final = st.text(alphabet=string.ascii_letters, min_size=3, max_size=8)
SURFACES_STRATEGY: Final = st.lists(
    st.sampled_from(sorted(COMBO_SURFACES)),
    min_size=1,
    max_size=len(COMBO_SURFACES),
    unique=True,
).map(frozenset)
OCCURRENCES_STRATEGY: Final = st.integers(min_value=1, max_value=3)


def _combo_value_texts(doc: pikepdf.Pdf, surfaces: frozenset[str]) -> list[str]:
    values = _string_values(doc)
    if "xmp" in surfaces:
        values.append(doc.Root.Metadata.read_bytes().decode("utf-8"))
    return values


_ID_RE: Final = re.compile(rb"/ID\s*\[\s*<([0-9A-Fa-f]+)>")

_REPLACEMENT_POOL: Final = "0123456789!@#$%^&*()-_=+[]{};:,.<>?/|~"


def _replacement_for(target: str, marker: str) -> str:
    used = set(target) | set(marker)
    pool = [c for c in _REPLACEMENT_POOL if c not in used]
    assert pool, f"replacement pool exhausted by target={target!r} marker={marker!r}"
    return "".join(pool[:6])


def _fixture_id_digest(raw: bytes) -> bytes:
    m = _ID_RE.search(raw)
    return bytes.fromhex(m.group(1).decode("ascii")) if m else b""


@settings(
    max_examples=30,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture, HealthCheck.too_slow],
)
@given(
    target=TARGET_STRATEGY,
    marker=MARKER_STRATEGY,
    surfaces=SURFACES_STRATEGY,
    occurrences=OCCURRENCES_STRATEGY,
)
def test_scrub_completeness_and_preservation_across_surfaces(
    cli_binary: Path,
    target: str,
    marker: str,
    surfaces: frozenset[str],
    occurrences: int,
) -> None:
    if marker in target or target in marker:
        return
    if target in _BENIGN_STREAM_TEXT or (
        "xmp" in surfaces and target in _XMP_WRAPPER_TEXT
    ):
        return

    with tempfile.TemporaryDirectory(prefix="nullmark-hyp-") as tmp:
        tmp_path = Path(tmp)
        in_pdf = tmp_path / "in.pdf"
        out_pdf = tmp_path / "out.pdf"
        build_combo(in_pdf, target, marker, surfaces, occurrences=occurrences)
        with pikepdf.open(in_pdf) as in_doc:
            in_values = _combo_value_texts(in_doc, surfaces)
            in_names = _name_values(in_doc)
        assert any(target in v for v in in_values), (
            "fixture does not carry the target in any decoded string value"
        )
        unremovable = any(target in n for n in in_names) or (
            target.encode("utf-8") in _fixture_id_digest(in_pdf.read_bytes())
        )

        result = run_cli(
            cli_binary, in_pdf, out_pdf, target, _replacement_for(target, marker)
        )
        fields = result_fields(result.stdout)

        if fields["rc"] != 0 or fields["residual"] != 0:
            assert not out_pdf.exists(), (
                f"wrote output for a target left in the file's structure; "
                f"stdout={result.stdout!r}"
            )
            assert unremovable, (
                f"refused a removable target; target={target!r} "
                f"surfaces={sorted(surfaces)} stdout={result.stdout!r}"
            )
            return

        assert out_pdf.exists(), (
            f"CLI reported a clean run but wrote no output; "
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )
        assert fields["matches"] >= 1, (
            f"no replacement counted; stdout={result.stdout!r}"
        )

        with pikepdf.open(in_pdf) as in_doc, pikepdf.open(out_pdf) as out_doc:
            out_values = _combo_value_texts(out_doc, surfaces)
            assert not any(target in v for v in out_values), (
                f"target survives on some surface of {sorted(surfaces)} "
                f"(decoded-string scan); target={target!r}"
            )
            assert any(marker in v for v in out_values), (
                f"unrelated marker value lost while scrubbing {sorted(surfaces)}; "
                f"marker={marker!r}"
            )

            assert in_doc.pdf_version == out_doc.pdf_version, (
                "PDF header version changed"
            )
            assert id_pair(in_doc) == id_pair(out_doc), "/ID array changed"


@settings(
    max_examples=15,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(surfaces=SURFACES_STRATEGY, marker=MARKER_STRATEGY)
def test_empty_target_fails_closed(
    cli_binary: Path, surfaces: frozenset[str], marker: str
) -> None:
    with tempfile.TemporaryDirectory(prefix="nullmark-hyp-empty-") as tmp:
        tmp_path = Path(tmp)
        in_pdf = tmp_path / "in.pdf"
        out_pdf = tmp_path / "out.pdf"
        build_combo(in_pdf, "sentinel-target", marker, surfaces, occurrences=1)

        result = run_cli(cli_binary, in_pdf, out_pdf, "", REPLACEMENT)
        fields = result_fields(result.stdout)
        assert fields["rc"] == 1, (
            f"empty target did not fail closed; stdout={result.stdout!r}"
        )
        assert fields["matches"] == 0, (
            f"empty target counted as a match; stdout={result.stdout!r}"
        )
        assert fields["residual"] == 0, (
            f"empty target counted as residual; stdout={result.stdout!r}"
        )
        assert not out_pdf.exists(), (
            "fail-closed violated: output kept for an empty target; "
            f"stdout={result.stdout!r}"
        )
        assert "empty" in result.stdout, (
            f"no explanatory error for an empty target; stdout={result.stdout!r}"
        )


@settings(
    max_examples=10,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(replace=st.text(max_size=16).filter(lambda s: "\x00" not in s))
def test_empty_target_against_page_text_fixtures_fails_closed(
    cli_binary: Path, tmp_path_factory: pytest.TempPathFactory, replace: str
) -> None:
    fixtures = generate_all(
        tmp_path_factory.mktemp("nullmark-hyp-page"), target="OLDNAME"
    )
    with tempfile.TemporaryDirectory(prefix="nullmark-hyp-page-run-") as tmp:
        tmp_path = Path(tmp)
        for name in ("simple", "multipage"):
            in_pdf = fixtures[name]
            assert in_pdf is not None
            out_pdf = tmp_path / f"{name}.out.pdf"
            result = run_cli(cli_binary, in_pdf, out_pdf, "", replace)
            fields = result_fields(result.stdout)
            assert fields["rc"] == 1, (
                f"{name}: empty target did not fail closed; stdout={result.stdout!r}"
            )
            assert fields["matches"] == 0, (
                f"{name}: empty target matched; stdout={result.stdout!r}"
            )
            assert fields["residual"] == 0, (
                f"{name}: empty target left residual; stdout={result.stdout!r}"
            )
            assert not out_pdf.exists(), (
                f"{name}: fail-closed violated: output kept for an empty target; "
                f"stdout={result.stdout!r}"
            )
