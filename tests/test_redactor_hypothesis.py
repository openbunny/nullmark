from __future__ import annotations

import re
import shutil
import string
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Final

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

sys.path.insert(0, str(Path(__file__).parent))
import pdfutil as pdf
from fixtures.generate import (
    BENIGN_BODY,
    COMBO_SURFACES,
    XMP_TEMPLATE,
    build_combo,
    generate_all,
)

NULLMARK_DIR: Final = Path(__file__).resolve().parents[1]
MUPDF_INCLUDE: Final = Path("/opt/homebrew/include")
MUPDF_LIB: Final = Path("/opt/homebrew/lib")
_BENIGN_STREAM_TEXT: Final = BENIGN_BODY.decode("latin-1")
_XMP_WRAPPER_TEXT: Final = XMP_TEMPLATE.format(title="")
REPLACEMENT: Final = "NEWNAME"


def _mupdf_available() -> bool:
    return bool(
        (MUPDF_INCLUDE / "mupdf" / "fitz.h").exists()
        and list(MUPDF_LIB.glob("libmupdf.*"))
        and shutil.which("cc")
        and shutil.which("mutool")
    )


if not _mupdf_available():
    pytest.skip(
        "mupdf not found under /opt/homebrew (brew install mupdf), or no `cc`/`mutool` on PATH",
        allow_module_level=True,
    )


@pytest.fixture(scope="session")
def cli_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("nullmark-cli-hyp") / "task4pdf_cli"
    subprocess.run(
        [
            "cc",
            "-DT4_MAIN",
            "-std=c11",
            "-I",
            str(NULLMARK_DIR / "CTask4PDF" / "include"),
            "-I",
            str(MUPDF_INCLUDE),
            "-L",
            str(MUPDF_LIB),
            f"-Wl,-rpath,{MUPDF_LIB}",
            str(NULLMARK_DIR / "CTask4PDF" / "task4pdf.c"),
            "-lmupdf",
            "-o",
            str(out),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return out


def _clean(path: Path, dest: Path) -> str:
    subprocess.run(
        ["mutool", "clean", "-d", str(path), str(dest)], check=True, capture_output=True
    )
    return dest.read_bytes().decode("latin-1")


def _run_cli(
    cli: Path, in_pdf: Path, out_pdf: Path, find: str, replace: str
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(cli), str(in_pdf), str(out_pdf), find, replace],
        capture_output=True,
        text=True,
        check=False,
    )


def _result_fields(stdout: str) -> dict[str, int]:
    return {
        k: int(v) for k, v in re.findall(r"(rc|matches|pages|residual)=(-?\d+)", stdout)
    }


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


def _combo_value_texts(text: str, surfaces: frozenset[str]) -> list[str]:
    values = pdf.string_values(text)
    if "xmp" in surfaces:
        trailer = pdf.trailer_dict(text)
        root = pdf.object_body(text, pdf.ref_num(trailer, "Root"))
        metadata = pdf.object_body(text, pdf.ref_num(root, "Metadata"))
        payload = pdf.stream_payload(metadata)
        values.append(payload.encode("latin-1").decode("utf-8"))
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
        in_clean = _clean(in_pdf, tmp_path / "in.clean.pdf")
        in_values = _combo_value_texts(in_clean, surfaces)
        assert any(target in v for v in in_values), (
            "fixture does not carry the target in any decoded string value"
        )
        unremovable = any(target in n for n in pdf.name_values(in_clean)) or (
            target.encode("utf-8") in _fixture_id_digest(in_pdf.read_bytes())
        )

        result = _run_cli(
            cli_binary, in_pdf, out_pdf, target, _replacement_for(target, marker)
        )
        fields = _result_fields(result.stdout)

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

        out_clean = _clean(out_pdf, tmp_path / "out.clean.pdf")
        out_values = _combo_value_texts(out_clean, surfaces)
        assert not any(target in v for v in out_values), (
            f"target survives on some surface of {sorted(surfaces)} "
            f"(decoded-string scan); target={target!r}"
        )
        assert any(marker in v for v in out_values), (
            f"unrelated marker value lost while scrubbing {sorted(surfaces)}; marker={marker!r}"
        )

        assert pdf.header_version(in_clean) == pdf.header_version(out_clean), (
            "PDF header version changed"
        )
        in_trailer, out_trailer = (
            pdf.trailer_dict(in_clean),
            pdf.trailer_dict(out_clean),
        )
        assert pdf.id_pair(in_trailer) == pdf.id_pair(out_trailer), "/ID array changed"


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

        result = _run_cli(cli_binary, in_pdf, out_pdf, "", REPLACEMENT)
        fields = _result_fields(result.stdout)
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
            f"fail-closed violated: output kept for an empty target; stdout={result.stdout!r}"
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
            result = _run_cli(cli_binary, in_pdf, out_pdf, "", replace)
            fields = _result_fields(result.stdout)
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
