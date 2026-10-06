from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING, Final

import pikepdf
import pytest

if TYPE_CHECKING:
    from collections.abc import Iterator

ROOT: Final = Path(__file__).resolve().parents[1]
TARGET: Final = "OLDNAME"
REPLACEMENT: Final = "NEWNAME"


@pytest.fixture(scope="session")
def cli_binary() -> Path:
    path = os.environ.get("NULLMARK_CLI")
    if not path:
        pytest.fail(
            "NULLMARK_CLI is unset; it names the CLI the CMake build produces. "
            "Run the suite through `just test`."
        )
    cli = Path(path)
    if not cli.is_file():
        pytest.fail(f"NULLMARK_CLI names {cli}, which does not exist; run `just test`.")
    return cli


def direct(obj: object) -> Iterator[pikepdf.Object]:
    if not isinstance(obj, pikepdf.Object):
        return
    yield obj
    if isinstance(obj, pikepdf.Array):
        children = list(obj)
    elif isinstance(obj, pikepdf.Dictionary | pikepdf.Stream):
        children = list(obj.values())
    else:
        return
    for child in children:
        if not (isinstance(child, pikepdf.Object) and child.is_indirect):
            yield from direct(child)


def graph(doc: pikepdf.Pdf) -> Iterator[pikepdf.Object]:
    for indirect in doc.objects:
        if not (
            isinstance(indirect, pikepdf.Stream) and indirect.get("/Type") == "/XRef"
        ):
            yield from direct(indirect)


def content_operands(doc: pikepdf.Pdf) -> Iterator[pikepdf.Object]:
    streams: list[pikepdf.Object] = [page.obj for page in doc.pages]
    for obj in graph(doc):
        if isinstance(obj, pikepdf.Stream) and (
            obj.get("/Subtype") == "/Form" or "/PatternType" in obj
        ):
            streams.append(obj)
        elif isinstance(obj, pikepdf.Dictionary) and "/CharProcs" in obj:
            streams.extend(obj.CharProcs.values())
    for stream in streams:
        for instruction in pikepdf.parse_content_stream(stream):
            for operand in instruction.operands:
                yield from direct(operand)


def string_text(value: pikepdf.String) -> str:
    raw = bytes(value)
    if raw[:2] == b"\xfe\xff":
        return raw[2:].decode("utf-16-be", "surrogatepass")
    return raw.decode("latin-1")


def id_pair(doc: pikepdf.Pdf) -> tuple[bytes, ...]:
    return tuple(bytes(element) for element in doc.trailer.ID)


def run_cli(
    cli: Path,
    in_pdf: Path,
    out_pdf: Path,
    find: str = TARGET,
    replace: str = REPLACEMENT,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(cli), str(in_pdf), str(out_pdf), find, replace],
        capture_output=True,
        text=True,
        check=False,
    )


def result_fields(stdout: str) -> dict[str, int]:
    return {
        k: int(v) for k, v in re.findall(r"(rc|matches|pages|residual)=(-?\d+)", stdout)
    }
