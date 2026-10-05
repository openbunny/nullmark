from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Final

TARGET: Final = "OLDNAME"
REPLACEMENT: Final = "NEWNAME"
XMP: Final = (
    b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta '
    b'xmlns:x="adobe:ns:meta/"></x:xmpmeta><?xpacket end="w"?>'
)
CASES: Final = {
    "simple": [f"Statement for {TARGET} account"],
    "multipage": [f"Page {n}: {TARGET} here" for n in (1, 2, 3)],
}
_FIELD_RE: Final = r"/%s\s*(\[.*?\]|\(.*?\)|<[0-9A-Fa-f]*>|/[^\s/>]+|\d+ \d+ R)"


def build(path: Path, lines: list[str]) -> None:
    objs: list[bytes] = []

    def add(body: bytes) -> int:
        objs.append(body)
        return len(objs)

    font = add(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )
    contents = [
        add(b"<< /Length %d >>\nstream\n" % len(c) + c + b"\nendstream")
        for c in (
            b"BT /F1 18 Tf 72 700 Td (" + t.encode("latin-1") + b") Tj ET"
            for t in lines
        )
    ]
    meta = add(
        b"<< /Type /Metadata /Subtype /XML /Length %d >>\nstream\n" % len(XMP)
        + XMP
        + b"\nendstream"
    )
    info = add(
        b"<< /Title (T4 verify) /Author (T4) /Producer (t4-verify) /CreationDate (D:20240101000000Z) >>"
    )
    page_nums = [
        add(
            b"<< /Type /Page /Parent PAGES 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
            % (font, content)
        )
        for content in contents
    ]
    kids = b" ".join(b"%d 0 R" % p for p in page_nums)
    pages = add(b"<< /Type /Pages /Kids [" + kids + b"] /Count %d >>" % len(page_nums))
    catalog = add(
        b"<< /Type /Catalog /Pages %d 0 R /Metadata %d 0 R >>" % (pages, meta)
    )
    buf = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets: list[int] = []
    for i, body in enumerate(
        (o.replace(b"PAGES 0 R", b"%d 0 R" % pages) for o in objs), 1
    ):
        offsets.append(len(buf))
        buf += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(buf)
    buf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    buf += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    digest = os.urandom(16).hex().encode()
    buf += (
        b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R /ID [<%s> <%s>] >>\nstartxref\n%d\n%%%%EOF\n"
        % (
            len(objs) + 1,
            catalog,
            info,
            digest,
            digest,
            xref,
        )
    )
    path.write_bytes(buf)


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


def run_case(work: Path, sandbox_run: Path, name: str, lines: list[str]) -> bool:
    src, out = work / f"{name}.pdf", work / f"{name}.out.pdf"
    build(src, lines)
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
        "header_same": in_clean[:8] == out_clean[:8],
        "ID_same": field(in_clean, "ID") == field(out_clean, "ID"),
        "Info_same": all(
            field(in_clean, k) == field(out_clean, k) for k in ("Producer", "Title")
        ),
    }
    ok = all(checks.values())
    print(
        name,
        "PASS" if ok else "FAIL",
        "" if ok else checks,
        "| cli:",
        result.stdout.strip(),
    )
    return ok


def main(work: Path, here: Path) -> int:
    sandbox_run = here / "sandbox" / "run-sandboxed.sh"
    results = [
        run_case(work, sandbox_run, name, lines) for name, lines in CASES.items()
    ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
