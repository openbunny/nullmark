from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Final

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import pdfutil as pdf
from fixtures.generate import (
    build_astral_info_only,
    build_cidfont,
    build_deep_nesting,
    build_incremental_update,
    build_key_only,
    build_kitchen_sink,
    build_nul_name_only,
    build_nul_string_only,
    build_oversized_xmp,
    build_trailer_junk_only,
    build_xmp_only,
    generate_all,
)
from mupdf_discovery import discover_mupdf

NULLMARK_DIR: Final = Path(__file__).resolve().parents[1]
TARGET: Final = "OLDNAME"
REPLACEMENT: Final = "NEWNAME"

_DISCOVERED: Final = discover_mupdf()
MUPDF_INCLUDE: Final = _DISCOVERED[0] if _DISCOVERED else Path("/opt/homebrew/include")
MUPDF_LIB: Final = _DISCOVERED[1] if _DISCOVERED else Path("/opt/homebrew/lib")


def _mupdf_available() -> bool:
    return bool(_DISCOVERED and shutil.which("cc") and shutil.which("mutool"))


if not _mupdf_available():
    _reason = (
        "mupdf not found (checked pkg-config, `brew --prefix mupdf`, /opt/homebrew and "
        "/usr/local), or no `cc`/`mutool` on PATH."
    )
    if os.environ.get("NULLMARK_REQUIRE_MUPDF"):
        pytest.fail(
            f"{_reason} NULLMARK_REQUIRE_MUPDF is set, so this is an error, not a skip."
        )
    pytest.skip(
        f"{_reason} Set NULLMARK_REQUIRE_MUPDF=1 to fail instead of skipping.",
        allow_module_level=True,
    )


@pytest.fixture(scope="session")
def cli_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("nullmark-cli") / "task4pdf_cli"
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


@pytest.fixture(scope="session")
def fixture_pdfs(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path | None]:
    return generate_all(tmp_path_factory.mktemp("nullmark-fixtures"), target=TARGET)


def _clean(path: Path, dest: Path) -> str:
    subprocess.run(
        ["mutool", "clean", "-d", str(path), str(dest)], check=True, capture_output=True
    )
    return dest.read_bytes().decode("latin-1")


def _extract_text(path: Path) -> str:
    r = subprocess.run(
        ["mutool", "convert", "-F", "text", "-o", "-", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return r.stdout


def _run_cli(
    cli: Path, in_pdf: Path, out_pdf: Path
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(cli), str(in_pdf), str(out_pdf), TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )


def _result_fields(stdout: str) -> dict[str, int]:
    return {
        k: int(v) for k, v in re.findall(r"(rc|matches|pages|residual)=(-?\d+)", stdout)
    }


@pytest.mark.parametrize("name", ["simple", "multipage", "cidfont"])
def test_replace_preserves_metadata(
    name: str, cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs[name]
    assert in_pdf is not None, f"{name} fixture was not generated"

    out_pdf = tmp_path / f"{name}.out.pdf"
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    assert out_pdf.exists(), (
        f"CLI produced no output file; stdout={result.stdout!r} "
        f"stderr={result.stderr!r}"
    )

    extracted = _extract_text(out_pdf)
    assert TARGET not in extracted, (
        "target text still present after redaction (zero-residual requirement "
        "violated): "
        f"{extracted!r}; CLI stdout={result.stdout!r}"
    )
    assert REPLACEMENT in extracted, (
        f"replacement text missing from output: {extracted!r}"
    )

    raw_out = out_pdf.read_bytes()
    assert raw_out.count(b"%%EOF") == 1, "output must have exactly one %%EOF"
    assert b"/Prev" not in raw_out, (
        "output must not be an incremental update (no /Prev)"
    )
    assert not re.search(rb"MuPDF[ \t]+\d", raw_out, re.IGNORECASE), (
        "output must not carry a MuPDF version string "
        "(checked on the CLI's raw output, not on a `mutool clean` copy). MuPDF's own "
        "save "
        "always stamps a versionless '% Written by MuPDF' product comment that the "
        "supported "
        "save API cannot suppress, so only a 'MuPDF <digit>' version pattern is "
        "rejected)"
    )

    in_text = _clean(in_pdf, tmp_path / f"{name}.in.clean.pdf")
    out_text = _clean(out_pdf, tmp_path / f"{name}.out.clean.pdf")

    assert pdf.header_version(in_text) == pdf.header_version(out_text), (
        "PDF header version changed"
    )

    if name != "cidfont":
        assert TARGET not in out_text, (
            "target text literally present in the decompressed content stream"
        )

    in_trailer, out_trailer = pdf.trailer_dict(in_text), pdf.trailer_dict(out_text)
    assert pdf.id_pair(in_trailer) == pdf.id_pair(out_trailer), "/ID array changed"

    in_info = pdf.object_body(in_text, pdf.ref_num(in_trailer, "Info"))
    out_info = pdf.object_body(out_text, pdf.ref_num(out_trailer, "Info"))
    assert pdf.normalize_ws(in_info) == pdf.normalize_ws(out_info), (
        "Info dictionary changed"
    )

    in_root = pdf.object_body(in_text, pdf.ref_num(in_trailer, "Root"))
    out_root = pdf.object_body(out_text, pdf.ref_num(out_trailer, "Root"))
    in_xmp = pdf.stream_payload(
        pdf.object_body(in_text, pdf.ref_num(in_root, "Metadata"))
    )
    out_xmp = pdf.stream_payload(
        pdf.object_body(out_text, pdf.ref_num(out_root, "Metadata"))
    )
    assert in_xmp == out_xmp, "XMP packet changed"


SCRUBBED_SURFACES: Final = {
    "info": "Nullmark info fixture",
    "xmp": "Nullmark xmp fixture",
    "outline": "Nullmark outline fixture",
    "annotation": "Nullmark annotation fixture",
    "field": "fullname",
    "objstm": "Nullmark info fixture",
    "name_value": "Nullmark name-value fixture",
}

UNRELATED_INFO_FIELDS: Final = {
    "Creator": "(nullmark-fixture-generator)",
    "Producer": "(nullmark-fixture-generator)",
    "CreationDate": "(D:20240101000000Z)",
}


@pytest.mark.parametrize("name", sorted(SCRUBBED_SURFACES))
def test_scrub_removes_target_from_surface(
    name: str, cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs[name]
    assert in_pdf is not None, f"{name} fixture was not generated"

    in_clean = _clean(in_pdf, tmp_path / f"{name}.in.clean.pdf")
    assert TARGET in in_clean, (
        f"fixture {name} does not carry the target on its surface"
    )

    out_pdf = tmp_path / f"{name}.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)
    assert out_pdf.exists(), (
        f"CLI produced no output; stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"non-zero rc; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"
    assert fields["matches"] >= 1, (
        f"no replacement counted on {name}; stdout={result.stdout!r}"
    )

    out_clean = _clean(out_pdf, tmp_path / f"{name}.out.clean.pdf")
    assert TARGET not in out_clean, (
        f"target survives on the {name} surface (independent scan)"
    )
    assert REPLACEMENT in out_clean, f"replacement missing on the {name} surface"
    assert SCRUBBED_SURFACES[name] in out_clean, f"unrelated metadata changed on {name}"

    if name in ("info", "objstm"):
        in_trailer, out_trailer = (
            pdf.trailer_dict(in_clean),
            pdf.trailer_dict(out_clean),
        )
        in_info = pdf.object_body(in_clean, pdf.ref_num(in_trailer, "Info"))
        out_info = pdf.object_body(out_clean, pdf.ref_num(out_trailer, "Info"))
        for key, expected in UNRELATED_INFO_FIELDS.items():
            in_m = re.search(rf"/{key}\s*(\(.*?\)|<.*?>)", in_info)
            out_m = re.search(rf"/{key}\s*(\(.*?\)|<.*?>)", out_info)
            assert in_m, (
                f"fixture setup: /{key} missing from input Info dict: {in_info!r}"
            )
            assert in_m.group(1) == expected, (
                f"fixture setup: /{key} not {expected!r} in input Info dict: "
                f"{in_info!r}"
            )
            assert out_m, f"/{key} missing from output Info dict: {out_info!r}"
            assert out_m.group(1) == in_m.group(1), (
                f"unrelated Info field /{key} changed by scrub: "
                f"{in_m.group(1)!r} -> {out_m.group(1)!r}"
            )


def test_embedded_file_target_fails_closed(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["embedded"]
    assert in_pdf is not None, "embedded fixture was not generated"

    in_clean = _clean(in_pdf, tmp_path / "embedded.in.clean.pdf")
    assert TARGET in in_clean, (
        "embedded fixture does not carry the target in its file stream"
    )

    out_pdf = tmp_path / "embedded.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    fields = _result_fields(result.stdout)
    assert result.returncode != 0, (
        f"CLI reported success on an embedded target; {result.stdout!r}"
    )
    assert fields["residual"] >= 1, (
        f"embedded target not counted as residual; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept while an embedded target survives"
    )


def test_deep_nesting_fails_closed(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "deepnest.pdf"
    build_deep_nesting(in_pdf, TARGET)

    out_pdf = tmp_path / "deepnest.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    assert result.returncode != 0, (
        f"CLI must fail closed on directly-nested structure past the depth cap "
        f"instead of recursing without limit; {result.stdout!r} {result.stderr!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept despite exceeding the nesting depth cap"
    )


def test_oversized_stream_fails_closed(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "oversized_xmp.pdf"
    build_oversized_xmp(in_pdf)

    out_pdf = tmp_path / "oversized_xmp.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    assert result.returncode != 0, (
        f"CLI must fail closed on a stream that decompresses past the size cap "
        f"instead of decompressing it unconditionally; {result.stdout!r} "
        f"{result.stderr!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept despite an oversized decompressed stream"
    )


def test_appearance_stream_target_fails_closed(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["appearance"]
    assert in_pdf is not None, "appearance fixture was not generated"

    in_clean = _clean(in_pdf, tmp_path / "appearance.in.clean.pdf")
    assert TARGET in in_clean, (
        "appearance fixture does not carry the target in its /AP stream"
    )

    out_pdf = tmp_path / "appearance.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    fields = _result_fields(result.stdout)
    assert result.returncode != 0, (
        f"CLI reported success on an appearance-stream target; {result.stdout!r}"
    )
    assert fields["residual"] >= 1, (
        f"appearance-stream target not counted as residual; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept while an appearance-stream target survives"
    )


def test_incremental_update_remnants_dropped(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "incremental.pdf"
    build_incremental_update(in_pdf, TARGET)

    raw_in = in_pdf.read_bytes()
    assert TARGET.encode() in raw_in, (
        "fixture setup: target not in the stale base revision"
    )
    assert b"/Prev" in raw_in, (
        "fixture setup: input is not actually an incremental update"
    )

    out_pdf = tmp_path / "incremental.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)
    assert out_pdf.exists(), (
        f"CLI produced no output; stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"non-zero rc; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"

    raw_out = out_pdf.read_bytes()
    assert TARGET.encode() not in raw_out, (
        "the stale, no-longer-live incremental-update revision's target bytes survive "
        "in the raw output (independent of verify_residual, which only sees live "
        "values)"
    )
    assert raw_out.count(b"%%EOF") == 1, "output must have exactly one %%EOF"
    assert b"/Prev" not in raw_out, (
        "output must not be an incremental update (no /Prev)"
    )


ASTRAL_TARGET: Final = "OLD\U0001f600NAME"


@pytest.mark.parametrize("name", ["xmp", "info"])
def test_scrub_removes_astral_target(
    name: str, cli_binary: Path, tmp_path: Path
) -> None:
    in_pdf = tmp_path / f"{name}.astral.pdf"
    if name == "xmp":
        build_xmp_only(in_pdf, ASTRAL_TARGET)
    else:
        build_astral_info_only(in_pdf, ASTRAL_TARGET)

    out_pdf = tmp_path / f"{name}.astral.out.pdf"
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), ASTRAL_TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    assert out_pdf.exists(), (
        f"CLI produced no output; stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"non-zero rc; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"
    assert fields["matches"] >= 1, (
        f"no replacement counted on {name}; stdout={result.stdout!r}"
    )

    raw_out = out_pdf.read_bytes()
    assert ASTRAL_TARGET.encode("utf-8") not in raw_out, (
        "astral target survives as UTF-8 bytes"
    )
    assert ASTRAL_TARGET.encode("utf-16-be") not in raw_out, (
        "astral target survives as UTF-16BE (surrogate-pair) bytes"
    )
    assert (
        REPLACEMENT.encode("utf-8") in raw_out
        or REPLACEMENT.encode("utf-16-be") in raw_out
    ), "replacement missing from output"


def test_cli_rejects_empty_target(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["simple"]
    assert in_pdf is not None
    out_pdf = tmp_path / "empty_target.out.pdf"
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), "", REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0, (
        f"CLI accepted an empty find string; {result.stdout!r}"
    )
    assert "empty" in result.stdout.lower(), (
        f"missing expected error text; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept for an empty find string"
    )


def test_cli_rejects_oversized_target(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["simple"]
    assert in_pdf is not None
    out_pdf = tmp_path / "oversized_target.out.pdf"
    oversized = "A" * 257
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), oversized, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0, (
        f"CLI accepted a 257-codepoint find string; {result.stdout!r}"
    )
    assert "256" in result.stdout, (
        f"missing expected limit in error text; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept for an over-limit find string"
    )


def test_nul_truncated_string_fails_closed(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "nul.pdf"
    build_nul_string_only(in_pdf, TARGET)
    assert TARGET.encode() in in_pdf.read_bytes(), (
        "fixture setup: target missing from input"
    )
    out_pdf = tmp_path / "nul.out.pdf"
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0, (
        f"CLI shipped a file with NUL-blind content; {result.stdout!r}"
    )
    assert "string value" in result.stdout, f"wrong surface refused; {result.stdout!r}"
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept for NUL-blind content"
    )


def test_nul_escaped_name_scrubs_clean(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "nulname.pdf"
    build_nul_name_only(in_pdf, TARGET)
    assert TARGET.encode() in in_pdf.read_bytes(), (
        "fixture setup: target missing from input"
    )
    out_pdf = tmp_path / "nulname.out.pdf"
    result = subprocess.run(
        [str(cli_binary), str(in_pdf), str(out_pdf), TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"clean name refused; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"
    raw_out = out_pdf.read_bytes()
    assert TARGET.encode() not in raw_out, (
        "NUL-escaped name target survives in raw output"
    )
    assert REPLACEMENT.encode() in raw_out, "replacement missing from raw output"


def test_trailer_junk_scrubs_clean(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "trailer.pdf"
    build_trailer_junk_only(in_pdf, TARGET)
    assert TARGET.encode() in in_pdf.read_bytes(), (
        "fixture setup: target missing from input"
    )
    out_pdf = tmp_path / "trailer.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)
    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"trailer junk refused; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"
    raw_out = out_pdf.read_bytes()
    assert TARGET.encode() not in raw_out, (
        "trailer-parked target survives in raw output"
    )
    assert b"/Junk" not in raw_out, "parked trailer entry survives in raw output"


def test_key_bearing_target_fails_closed(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "key.pdf"
    build_key_only(in_pdf, TARGET)
    assert TARGET.encode() in in_pdf.read_bytes(), (
        "fixture setup: target missing from input"
    )
    out_pdf = tmp_path / "key.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)
    fields = _result_fields(result.stdout)
    assert result.returncode != 0, (
        f"CLI reported success on a key-bearing target; {result.stdout!r}"
    )
    assert fields["residual"] >= 1, (
        f"key-bearing target not counted as residual; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept while a key-bearing target survives"
    )


KITCHEN_SINK_SURFACE_COUNT: Final = 9


def test_scrub_kitchen_sink_all_surfaces(cli_binary: Path, tmp_path: Path) -> None:
    in_pdf = tmp_path / "kitchen_sink.pdf"
    build_kitchen_sink(in_pdf, TARGET)

    out_pdf = tmp_path / "kitchen_sink.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)
    assert out_pdf.exists(), (
        f"CLI produced no output; stdout={result.stdout!r} stderr={result.stderr!r}"
    )

    fields = _result_fields(result.stdout)
    assert fields["rc"] == 0, f"non-zero rc; stdout={result.stdout!r}"
    assert fields["residual"] == 0, f"residual not zero; stdout={result.stdout!r}"
    assert fields["matches"] >= KITCHEN_SINK_SURFACE_COUNT, (
        f"fewer matches than expected surfaces; {result.stdout!r}"
    )

    extracted = _extract_text(out_pdf)
    assert TARGET not in extracted, f"target text survives on the page: {extracted!r}"
    assert REPLACEMENT in extracted, f"replacement missing from the page: {extracted!r}"

    out_clean = _clean(out_pdf, tmp_path / "kitchen_sink.out.clean.pdf")
    assert TARGET not in out_clean, (
        "target survives somewhere in the combined fixture's output"
    )


def test_cidfont_fixture_builds_without_any_installed_font(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with monkeypatch.context() as m:
        m.setattr(Path, "exists", lambda _self: False)
        build_cidfont(tmp_path / "cidfont.pdf", TARGET)
    out = tmp_path / "cidfont.pdf"
    assert out.read_bytes().startswith(b"%PDF-"), "cidfont fixture was not written"


def test_utf16le_embedded_target_fails_closed(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["embedded_utf16le"]
    assert in_pdf is not None, "embedded_utf16le fixture was not generated"

    raw_in = in_pdf.read_bytes()
    needle_le = TARGET.encode("utf-16-le")
    assert needle_le in raw_in, "fixture does not carry the target as UTF-16LE bytes"
    assert TARGET.encode("utf-8") not in raw_in, (
        "fixture leaks a UTF-8 copy of the target, which would defeat this test"
    )
    assert TARGET.encode("utf-16-be") not in raw_in, (
        "fixture leaks a UTF-16BE copy of the target, which would defeat this test"
    )

    out_pdf = tmp_path / "embedded_utf16le.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    fields = _result_fields(result.stdout)
    assert result.returncode != 0, (
        f"CLI reported success on a UTF-16LE-only embedded target; {result.stdout!r}"
    )
    assert fields["residual"] >= 1, (
        f"UTF-16LE embedded target not counted as residual; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept while a UTF-16LE-only embedded target "
        "survives"
    )


def test_hidden_cid_annotation_fails_closed(
    cli_binary: Path, fixture_pdfs: dict[str, Path | None], tmp_path: Path
) -> None:
    in_pdf = fixture_pdfs["hidden_cid_annot"]
    if in_pdf is None:
        pytest.skip(
            "hidden_cid_annot fixture unavailable: the system TrueType font is "
            "missing or lacks the target's glyphs"
        )

    out_pdf = tmp_path / "hidden_cid_annot.out.pdf"
    result = _run_cli(cli_binary, in_pdf, out_pdf)

    fields = _result_fields(result.stdout)
    assert result.returncode != 0, (
        "CLI reported success on a hidden CID-font annotation target; "
        f"{result.stdout!r}"
    )
    assert fields["residual"] >= 1, (
        f"hidden CID-font annotation target not counted as residual; {result.stdout!r}"
    )
    assert not out_pdf.exists(), (
        "fail-closed violated: output kept while a hidden CID-font annotation target "
        "survives"
    )
