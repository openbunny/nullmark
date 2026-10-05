from __future__ import annotations

import re

_HEADER_RE = re.compile(r"%PDF-(\d\.\d)")
_TRAILER_RE = re.compile(r"trailer\s*\n?\s*<<(.*?)>>\s*\nstartxref", re.DOTALL)
_ID_RE = re.compile(r"/ID\s*\[")
_STREAM_RE = re.compile(r"stream\r?\n(.*?)\r?\nendstream", re.DOTALL)

_LITERAL_ESCAPES = {
    "n": 10,
    "r": 13,
    "t": 9,
    "b": 8,
    "f": 12,
    "(": 40,
    ")": 41,
    "\\": 92,
}
_MAX_OCTAL_ESCAPE_DIGITS = 3


def header_version(text: str) -> str:
    m = _HEADER_RE.match(text)
    assert m, "no %PDF-x.y header found"
    return m.group(1)


def trailer_dict(text: str) -> str:
    m = _TRAILER_RE.search(text)
    assert m, (
        "no trailer dict found (expected classic xref output from `mutool clean -d`)"
    )
    return m.group(1)


def _decode_pdf_string(s: str, i: int) -> tuple[bytes, int]:
    if s[i] == "<":
        j = s.index(">", i)
        digits = re.sub(r"\s+", "", s[i + 1 : j])
        if len(digits) % 2:
            digits += "0"
        return bytes.fromhex(digits), j + 1
    assert s[i] == "(", f"expected a PDF string at index {i}, found {s[i]!r}"
    out = bytearray()
    depth = 0
    j = i + 1
    while j < len(s):
        c = s[j]
        if c == "\\":
            n = s[j + 1]
            if n in "01234567":
                digits = n
                j += 2
                while (
                    j < len(s)
                    and len(digits) < _MAX_OCTAL_ESCAPE_DIGITS
                    and s[j] in "01234567"
                ):
                    digits += s[j]
                    j += 1
                out.append(int(digits, 8) & 0xFF)
                continue
            out.append(_LITERAL_ESCAPES.get(n, ord(n)))
            j += 2
            continue
        if c == "(":
            depth += 1
            out.append(ord(c))
        elif c == ")":
            if depth == 0:
                return bytes(out), j + 1
            depth -= 1
            out.append(ord(c))
        else:
            out.append(ord(c) & 0xFF)
        j += 1
    raise AssertionError("unterminated PDF literal string in /ID")


def id_pair(trailer: str) -> tuple[str, str]:
    m = _ID_RE.search(trailer)
    assert m, "no /ID array found in trailer"
    i = m.end()
    while trailer[i] in " \t\r\n":
        i += 1
    first, i = _decode_pdf_string(trailer, i)
    while trailer[i] in " \t\r\n":
        i += 1
    second, _ = _decode_pdf_string(trailer, i)
    return first.hex().upper(), second.hex().upper()


def ref_num(dict_body: str, key: str) -> int:
    m = re.search(rf"/{key}\s+(\d+)\s+0\s+R", dict_body)
    assert m, f"no /{key} indirect reference found"
    return int(m.group(1))


def object_body(text: str, num: int) -> str:
    m = re.search(rf"(?:^|\n){num} 0 obj\s*\n(.*?)\nendobj", text, re.DOTALL)
    assert m, f"object {num} 0 obj not found"
    return m.group(1)


def stream_payload(obj_body: str) -> str:
    m = _STREAM_RE.search(obj_body)
    assert m, "no stream payload found in object"
    return m.group(1)


def normalize_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def string_values(text: str) -> list[str]:
    trailer_at = re.search(r"\ntrailer\b", text)
    if trailer_at:
        text = text[: trailer_at.start()]
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(" or (c == "<" and (i + 1 >= n or text[i + 1] != "<")):
            try:
                raw, j = _decode_pdf_string(text, i)
            except (AssertionError, IndexError, ValueError):
                i += 1
                continue
            out.append(
                raw[2:].decode("utf-16-be", "surrogatepass")
                if raw[:2] == b"\xfe\xff"
                else raw.decode("latin-1")
            )
            i = j
        else:
            i += 1
    return out
