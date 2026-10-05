from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Final

from fixtures.generate import build_multipage, build_simple

if TYPE_CHECKING:
    from collections.abc import Callable

TARGET: Final = "OLDNAME"
REPLACEMENT: Final = "NEWNAME"
CASES: Final[dict[str, Callable[[Path, str], None]]] = {
    "simple": build_simple,
    "multipage": build_multipage,
}
_FIELD_RE: Final = r"/%s\s*(\[.*?\]|\(.*?\)|<[0-9A-Fa-f]*>|/[^\s/>]+|\d+ \d+ R)"
_HEADER_LEN: Final = len("%PDF-1.7")


def clean(path: Path) -> str:
    dest = path.with_name(path.name + ".clean")
    subprocess.run(
        ["mutool", "clean", "-d", str(path), str(dest)], check=True, capture_output=True
    )
    return dest.read_bytes().decode("latin-1")


def text(path: Path) -> str:
    return subprocess.run(
        ["mutool", "convert", "-F", "text", "-o", "-", str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def field(pdf: str, key: str) -> str | None:
    m = re.search(_FIELD_RE % key, pdf, re.DOTALL)
    return re.sub(r"\s+", " ", m.group(1)) if m else None


def run_case(
    work: Path, sandbox_run: Path, name: str, build: Callable[[Path, str], None]
) -> bool:
    src, out = work / f"{name}.pdf", work / f"{name}.out.pdf"
    build(src, TARGET)
    result = subprocess.run(
        [str(sandbox_run), str(work / "cli"), str(src), str(out), TARGET, REPLACEMENT],
        capture_output=True,
        text=True,
        check=False,
    )
    raw = out.read_bytes()
    extracted, in_clean, out_clean = text(out), clean(src), clean(out)
    checks = {
        "residual_absent": TARGET not in extracted,
        "replacement_present": REPLACEMENT in extracted,
        "single_EOF": raw.count(b"%%EOF") == 1,
        "no_Prev": b"/Prev" not in raw,
        "no_version": re.search(rb"MuPDF[ \t]+\d", raw) is None,
        "header_same": in_clean[:_HEADER_LEN] == out_clean[:_HEADER_LEN],
        "ID_same": field(in_clean, "ID") == field(out_clean, "ID"),
        "Info_same": all(
            field(in_clean, k) == field(out_clean, k) for k in ("Producer", "Title")
        ),
    }
    ok = all(checks.values())
    verdict = "PASS" if ok else f"FAIL {checks}"
    sys.stdout.write(f"{name} {verdict} | cli: {result.stdout.strip()}\n")
    return ok


def main(work: Path, here: Path) -> int:
    sandbox_run = here / "sandbox" / "run-sandboxed.sh"
    results = [
        run_case(work, sandbox_run, name, build) for name, build in CASES.items()
    ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
