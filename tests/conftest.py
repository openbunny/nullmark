from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Final

import pytest

ROOT: Final = Path(__file__).resolve().parents[1]
MUPDF: Final = Path("/opt/homebrew")
HARDENED: Final = (
    "-Wall",
    "-Wextra",
    "-Wpedantic",
    "-Werror",
    "-O2",
    "-fstack-protector-strong",
    "-D_FORTIFY_SOURCE=2",
    "-fPIE",
)


@pytest.fixture(scope="session")
def cli_binary(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("cli") / "nullmark-cli"
    subprocess.run(
        [
            "cc",
            "-DT4_MAIN",
            "-std=c11",
            *HARDENED,
            "-I",
            str(ROOT / "CTask4PDF" / "include"),
            "-I",
            str(MUPDF / "include"),
            "-L",
            str(MUPDF / "lib"),
            f"-Wl,-rpath,{MUPDF / 'lib'}",
            str(ROOT / "CTask4PDF" / "task4pdf.c"),
            "-lmupdf",
            "-o",
            str(out),
        ],
        check=True,
    )
    return out
