from __future__ import annotations

import io
import os
import subprocess
import zlib
from pathlib import Path
from typing import Final

C_MAX_DECOMPRESSED_STREAM_BYTES: Final = 64 * 1024 * 1024
C_MAX_CONTAINER_DEPTH: Final = 64

SYSTEM_TTF: Final = Path("/System/Library/Fonts/Supplemental/Arial.ttf")

XMP_TEMPLATE: Final = (
    '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '<dc:title><rdf:Alt><rdf:li xml:lang="x-default">{title}</rdf:li></rdf:Alt></dc:title>\n'
    "</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n"
    '<?xpacket end="w"?>'
)


def pdf_str(s: str) -> bytes:
    escaped = (
        s.encode("latin-1")
        .replace(b"\\", b"\\\\")
        .replace(b"(", b"\\(")
        .replace(b")", b"\\)")
    )
    return b"(" + escaped + b")"


def text_string_bytes(s: str) -> bytes:
    data = b"\xfe\xff" + s.encode("utf-16-be")
    return b"<" + data.hex().encode("ascii") + b">"


def pdf_str_utf16(s: str) -> bytes:
    data = b"\xfe\xff" + s.encode("utf-16-be")
    return b"<" + data.hex().encode("ascii") + b">"


def xmp_bytes(title: str) -> bytes:
    return XMP_TEMPLATE.format(title=title).encode("utf-8")


def info_dict_bytes(title: str) -> bytes:
    return (
        b"<< /Title "
        + pdf_str(title)
        + b" /Author "
        + pdf_str("Nullmark tests")
        + b" /Producer "
        + pdf_str("nullmark-fixture-generator")
        + b" /CreationDate (D:20240101000000Z) >>"
    )


class PdfBuilder:
    def __init__(self) -> None:
        self.objs: list[bytes | None] = []

    def reserve(self) -> int:
        self.objs.append(None)
        return len(self.objs)

    def set(self, num: int, body: bytes) -> None:
        self.objs[num - 1] = body

    def add(self, body: bytes) -> int:
        n = self.reserve()
        self.set(n, body)
        return n

    def add_stream(self, extra: bytes, data: bytes) -> int:
        head = b"<< " + extra + f" /Length {len(data)} >>\nstream\n".encode()
        return self.add(head + data + b"\nendstream")

    def add_flate_stream(self, extra: bytes, data: bytes) -> int:
        compressed = zlib.compress(data, 9)
        head = (
            b"<< "
            + extra
            + f" /Filter /FlateDecode /Length {len(compressed)} >>\nstream\n".encode()
        )
        return self.add(head + compressed + b"\nendstream")

    def render(
        self,
        root: int,
        info: int,
        id1: str,
        id2: str,
        version: str = "1.7",
        trailer_extra: bytes = b"",
    ) -> tuple[bytes, int]:
        assert all(o is not None for o in self.objs), "unset reserved object"
        buf = bytearray(f"%PDF-{version}\n".encode("latin-1"))
        buf += bytes([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        offsets = []
        for i, body in enumerate(self.objs, start=1):
            offsets.append(len(buf))
            buf += f"{i} 0 obj\n".encode("latin-1") + (body or b"") + b"\nendobj\n"
        xref_off = len(buf)
        buf += f"xref\n0 {len(self.objs) + 1}\n".encode("latin-1")
        buf += b"0000000000 65535 f \n"
        for off in offsets:
            buf += f"{off:010d} 00000 n \n".encode("latin-1")
        buf += (
            f"trailer\n<< /Size {len(self.objs) + 1} /Root {root} 0 R /Info {info} 0 R "
            f"/ID [<{id1}> <{id2}>]".encode("latin-1")
            + trailer_extra
            + f" >>\nstartxref\n{xref_off}\n%%EOF\n".encode("latin-1")
        )
        return bytes(buf), xref_off

    def write(
        self,
        path: Path,
        root: int,
        info: int,
        id1: str,
        id2: str,
        version: str = "1.7",
        trailer_extra: bytes = b"",
    ) -> None:
        data, _ = self.render(root, info, id1, id2, version, trailer_extra)
        path.write_bytes(data)


def _page_dict(
    pages: int, font_name: str, font_ref: int, content: int, extra: str = ""
) -> bytes:
    return (
        f"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] "
        f"/Resources << /Font << /{font_name} {font_ref} 0 R >> >> "
        f"/Contents {content} 0 R{extra} >>"
    ).encode()


BENIGN_BODY: Final = b"BT /F1 18 Tf 72 700 Td (Body text with no target.) Tj ET"


def _helvetica() -> bytes:
    return b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"


def build_simple(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )
    content = b.add_stream(
        b"",
        b"BT /F1 18 Tf 72 700 Td "
        + pdf_str(f"Statement for {target} account")
        + b" Tj ET",
    )
    page = b.add(_page_dict(pages, "F1", font, content))
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML", xmp_bytes("Nullmark simple fixture")
    )
    info = b.add(info_dict_bytes("Nullmark simple fixture"))
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(
        catalog,
        f"<< /Type /Catalog /Pages {pages} 0 R /Metadata {metadata} 0 R >>".encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)


def build_multipage(path: Path, target: str, n_pages: int = 3) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    )
    page_refs = []
    for i in range(1, n_pages + 1):
        content = b.add_stream(
            b"",
            b"BT /F1 18 Tf 72 700 Td "
            + pdf_str(f"Page {i}: {target} on this page")
            + b" Tj ET",
        )
        page_refs.append(b.add(_page_dict(pages, "F1", font, content)))
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML", xmp_bytes("Nullmark multipage fixture")
    )
    info = b.add(info_dict_bytes("Nullmark multipage fixture"))
    kids = " ".join(f"{p} 0 R" for p in page_refs)
    b.set(pages, f"<< /Type /Pages /Kids [{kids}] /Count {n_pages} >>".encode())
    b.set(
        catalog,
        f"<< /Type /Catalog /Pages {pages} 0 R /Metadata {metadata} 0 R >>".encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)


def _finish(
    b: PdfBuilder,
    path: Path,
    catalog: int,
    pages: int,
    page: int,
    info: int,
    catalog_extra: str = "",
    trailer_extra: bytes = b"",
) -> None:
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(
        catalog,
        f"<< /Type /Catalog /Pages {pages} 0 R{catalog_extra} >>".encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1, trailer_extra=trailer_extra)


def build_info_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark info fixture")
        + b" /Author "
        + pdf_str(target)
        + b" /Subject "
        + pdf_str(f"Records for {target}")
        + b" /Keywords "
        + pdf_str(target)
        + b" /Creator "
        + pdf_str("nullmark-fixture-generator")
        + b" /Producer "
        + pdf_str("nullmark-fixture-generator")
        + b" /DeadName "
        + pdf_str(target)
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_xmp_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML", xmp_bytes(f"Statement for {target}")
    )
    info = b.add(info_dict_bytes("Nullmark xmp fixture"))
    _finish(b, path, catalog, pages, page, info, f" /Metadata {metadata} 0 R")


def build_outline_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    outlines = b.reserve()
    item = b.reserve()
    b.set(
        item,
        (
            b"<< /Title "
            + pdf_str(f"Chapter about {target}")
            + f" /Parent {outlines} 0 R /Dest [{page} 0 R /Fit] >>".encode()
        ),
    )
    b.set(
        outlines,
        f"<< /Type /Outlines /First {item} 0 R /Last {item} 0 R /Count 1 >>".encode(),
    )
    info = b.add(info_dict_bytes("Nullmark outline fixture"))
    _finish(b, path, catalog, pages, page, info, f" /Outlines {outlines} 0 R")


def build_annotation_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    annot = b.add(
        b"<< /Type /Annot /Subtype /Text /Rect [72 700 92 720] /Contents "
        + pdf_str(f"Note regarding {target}")
        + b" /T "
        + pdf_str(target)
        + b" >>"
    )
    page = b.add(
        _page_dict(pages, "F1", font, content, extra=f" /Annots [{annot} 0 R]")
    )
    info = b.add(info_dict_bytes("Nullmark annotation fixture"))
    _finish(b, path, catalog, pages, page, info)


def build_field_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    field = b.reserve()
    page = b.add(
        _page_dict(pages, "F1", font, content, extra=f" /Annots [{field} 0 R]")
    )
    b.set(
        field,
        (
            b"<< /Type /Annot /Subtype /Widget /FT /Tx /Rect [72 650 300 680] /T "
            + pdf_str("fullname")
            + b" /V "
            + pdf_str(f"{target} on file")
            + b" /DV "
            + pdf_str(target)
            + f" /P {page} 0 R >>".encode()
        ),
    )
    acroform = b.add(f"<< /Fields [{field} 0 R] /NeedAppearances true >>".encode())
    info = b.add(info_dict_bytes("Nullmark field fixture"))
    _finish(b, path, catalog, pages, page, info, f" /AcroForm {acroform} 0 R")


def build_deep_nesting(
    path: Path, target: str, depth: int = C_MAX_CONTAINER_DEPTH + 36
) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(info_dict_bytes("Nullmark deep-nesting fixture"))
    nested = pdf_str(target)
    for _ in range(depth):
        nested = b"[" + nested + b"]"
    b.add(nested)
    _finish(b, path, catalog, pages, page, info)


def build_oversized_xmp(path: Path) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    oversized = b"A" * (C_MAX_DECOMPRESSED_STREAM_BYTES + 1024)
    metadata = b.add_flate_stream(b"/Type /Metadata /Subtype /XML", oversized)
    info = b.add(info_dict_bytes("Nullmark oversized-xmp fixture"))
    _finish(b, path, catalog, pages, page, info, f" /Metadata {metadata} 0 R")


COMBO_SURFACES: Final = frozenset({"info", "xmp", "outline", "annotation", "field"})


def build_combo(
    path: Path, target: str, marker: str, surfaces: frozenset[str], occurrences: int = 1
) -> None:
    assert surfaces <= COMBO_SURFACES, (
        f"unknown surface(s): {surfaces - COMBO_SURFACES}"
    )
    repeated = f" {marker} ".join([target] * occurrences)

    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)

    field_ref = b.reserve() if "field" in surfaces else None
    annots = [field_ref] if field_ref is not None else []
    if "annotation" in surfaces:
        annots.append(
            b.add(
                b"<< /Type /Annot /Subtype /Text /Rect [72 700 92 720] /Contents "
                + text_string_bytes(f"note about {repeated}")
                + b" /T "
                + text_string_bytes(marker)
                + b" >>"
            )
        )
    page_extra = f" /Annots [{' '.join(f'{a} 0 R' for a in annots)}]" if annots else ""
    page = b.add(_page_dict(pages, "F1", font, content, extra=page_extra))

    if field_ref is not None:
        b.set(
            field_ref,
            (
                b"<< /Type /Annot /Subtype /Widget /FT /Tx /Rect [72 650 300 680] /T "
                + text_string_bytes(marker)
                + b" /V "
                + text_string_bytes(repeated)
                + b" /DV "
                + text_string_bytes(marker)
                + f" /P {page} 0 R >>".encode()
            ),
        )

    catalog_extra = ""
    if "outline" in surfaces:
        outlines = b.reserve()
        item = b.reserve()
        b.set(
            item,
            b"<< /Title "
            + text_string_bytes(repeated)
            + f" /Parent {outlines} 0 R /Dest [{page} 0 R /Fit] >>".encode(),
        )
        b.set(
            outlines,
            f"<< /Type /Outlines /First {item} 0 R /Last {item} 0 R /Count 1 >>".encode(),
        )
        catalog_extra += f" /Outlines {outlines} 0 R"

    if "xmp" in surfaces:
        metadata = b.add_stream(
            b"/Type /Metadata /Subtype /XML", xmp_bytes(f"{marker}: {repeated}")
        )
        catalog_extra += f" /Metadata {metadata} 0 R"

    if field_ref is not None:
        acroform = b.add(
            f"<< /Fields [{field_ref} 0 R] /NeedAppearances true >>".encode()
        )
        catalog_extra += f" /AcroForm {acroform} 0 R"

    if "info" in surfaces:
        info = b.add(
            b"<< /Title "
            + text_string_bytes(marker)
            + b" /Author "
            + text_string_bytes(repeated)
            + b" /Producer "
            + pdf_str("nullmark-hypothesis-fixture")
            + b" /CreationDate (D:20240101000000Z) >>"
        )
    else:
        info = b.add(info_dict_bytes(marker))

    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(catalog, f"<< /Type /Catalog /Pages {pages} 0 R{catalog_extra} >>".encode())
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)


def build_embedded_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    payload = f"Account holder: {target}\nBalance: 100 USD\n".encode("latin-1")
    ef = b.add_stream(b"/Type /EmbeddedFile /Subtype (text/plain)", payload)
    filespec = b.add(
        f"<< /Type /Filespec /F (statement.txt) /EF << /F {ef} 0 R >> >>".encode()
    )
    names = b.add(
        b"<< /EmbeddedFiles << /Names [(statement.txt) "
        + f"{filespec} 0 R] >> >>".encode()
    )
    info = b.add(info_dict_bytes("Nullmark embedded fixture"))
    _finish(b, path, catalog, pages, page, info, f" /Names {names} 0 R")


def build_compressed_objstm(path: Path, target: str) -> None:
    classic = path.with_name(path.stem + ".classic.pdf")
    build_info_only(classic, target)
    subprocess.run(
        ["mutool", "clean", "-Z", str(classic), str(path)],
        check=True,
        capture_output=True,
    )


def build_appearance_stream_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    ap_content = b"q BT /F1 12 Tf 0 10 Td " + pdf_str(f"Signed: {target}") + b" Tj ET Q"
    ap_resources = (
        f"/Type /XObject /Subtype /Form /BBox [0 0 200 40] "
        f"/Resources << /Font << /F1 {font} 0 R >> >>"
    )
    ap_stream = b.add_stream(ap_resources.encode(), ap_content)
    annot = b.add(
        b"<< /Type /Annot /Subtype /FreeText /Rect [72 600 272 640] /Contents "
        + pdf_str("baked appearance")
        + f" /AP << /N {ap_stream} 0 R >> >>".encode()
    )
    page = b.add(
        _page_dict(pages, "F1", font, content, extra=f" /Annots [{annot} 0 R]")
    )
    info = b.add(info_dict_bytes("Nullmark appearance fixture"))
    _finish(b, path, catalog, pages, page, info)


def build_astral_info_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark astral info fixture")
        + b" /Author "
        + pdf_str_utf16(target)
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_incremental_update(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark incremental fixture")
        + b" /Author "
        + pdf_str(target)
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(catalog, f"<< /Type /Catalog /Pages {pages} 0 R >>".encode())
    id1 = os.urandom(16).hex()
    base, base_xref_off = b.render(catalog, info, id1, id1)

    clean_info = (
        b"<< /Title "
        + pdf_str("Nullmark incremental fixture")
        + b" /Author "
        + pdf_str("REDACTED BY PRIOR EDIT")
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    buf = bytearray(base)
    upd_off = len(buf)
    buf += f"{info} 0 obj\n".encode("latin-1") + clean_info + b"\nendobj\n"
    xref_off = len(buf)
    size = len(b.objs) + 1
    buf += f"xref\n{info} 1\n".encode("latin-1")
    buf += f"{upd_off:010d} 00000 n \n".encode("latin-1")
    buf += (
        f"trailer\n<< /Size {size} /Root {catalog} 0 R /Info {info} 0 R "
        f"/ID [<{id1}> <{id1}>] /Prev {base_xref_off} >>\nstartxref\n{xref_off}\n%%EOF\n"
    ).encode("latin-1")
    path.write_bytes(bytes(buf))


def build_kitchen_sink(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(
        b"",
        b"BT /F1 18 Tf 72 700 Td "
        + pdf_str(f"Statement for {target} account")
        + b" Tj ET",
    )
    field = b.reserve()
    annot = b.add(
        b"<< /Type /Annot /Subtype /Text /Rect [72 680 92 700] /Contents "
        + pdf_str(f"Note regarding {target}")
        + b" /T "
        + pdf_str(target)
        + b" >>"
    )
    page = b.add(
        _page_dict(
            pages, "F1", font, content, extra=f" /Annots [{annot} 0 R {field} 0 R]"
        )
    )
    b.set(
        field,
        (
            b"<< /Type /Annot /Subtype /Widget /FT /Tx /Rect [72 650 300 680] /T "
            + pdf_str("fullname")
            + b" /V "
            + pdf_str(f"{target} on file")
            + b" /DV "
            + pdf_str(target)
            + f" /P {page} 0 R >>".encode()
        ),
    )
    acroform = b.add(f"<< /Fields [{field} 0 R] /NeedAppearances true >>".encode())
    outlines = b.reserve()
    item = b.reserve()
    b.set(
        item,
        (
            b"<< /Title "
            + pdf_str(f"Chapter about {target}")
            + f" /Parent {outlines} 0 R /Dest [{page} 0 R /Fit] >>".encode()
        ),
    )
    b.set(
        outlines,
        f"<< /Type /Outlines /First {item} 0 R /Last {item} 0 R /Count 1 >>".encode(),
    )
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML", xmp_bytes(f"Statement for {target}")
    )
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark kitchen-sink fixture")
        + b" /Author "
        + pdf_str(target)
        + b" /Subject "
        + pdf_str(f"Records for {target}")
        + b" /Creator "
        + pdf_str("nullmark-fixture-generator")
        + b" /Producer "
        + pdf_str("nullmark-fixture-generator")
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(
        catalog,
        (
            f"<< /Type /Catalog /Pages {pages} 0 R /Metadata {metadata} 0 R "
            f"/Outlines {outlines} 0 R /AcroForm {acroform} 0 R >>"
        ).encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)


def build_name_value_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark name-value fixture")
        + b" /Author "
        + pdf_str("Nullmark tests")
        + b" /Producer "
        + pdf_str("nullmark-fixture-generator")
        + b" /ClientRef /"
        + target.encode("latin-1")
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_nul_string_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark NUL string fixture")
        + b" /Subject (Records\\001\\000 for "
        + target.encode("latin-1")
        + b")"
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_nul_name_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark NUL name fixture")
        + b" /ClientRef /Ref#00"
        + target.encode("latin-1")
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_trailer_junk_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(info_dict_bytes("Nullmark trailer fixture"))
    _finish(
        b,
        path,
        catalog,
        pages,
        page,
        info,
        trailer_extra=b" /Junk << /Title " + pdf_str(target) + b" >>",
    )


def build_key_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    info = b.add(
        b"<< /Title "
        + pdf_str("Nullmark key fixture")
        + b" /Client"
        + target.encode("latin-1")
        + b" (benign)"
        + b" /CreationDate (D:20240101000000Z) >>"
    )
    _finish(b, path, catalog, pages, page, info)


def build_embedded_utf16le_only(path: Path, target: str) -> None:
    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    font = b.add(_helvetica())
    content = b.add_stream(b"", BENIGN_BODY)
    page = b.add(_page_dict(pages, "F1", font, content))
    payload = f"{target} on file\nBalance: 100 USD\n".encode("utf-16-le")
    ef = b.add_stream(b"/Type /EmbeddedFile /Subtype (text/plain)", payload)
    filespec = b.add(
        f"<< /Type /Filespec /F (statement.txt) /EF << /F {ef} 0 R >> >>".encode()
    )
    names = b.add(
        b"<< /EmbeddedFiles << /Names [(statement.txt) "
        + f"{filespec} 0 R] >> >>".encode()
    )
    info = b.add(info_dict_bytes("Nullmark embedded utf16le fixture"))
    _finish(b, path, catalog, pages, page, info, f" /Names {names} 0 R")


def _tounicode_cmap(entries: set[tuple[int, int]]) -> bytes:
    lines = "\n".join(f"<{gid:04X}> <{cp:04X}>" for gid, cp in sorted(entries))
    return (
        "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        "/CMapName /Nullmark-UCS def\n/CMapType 2 def\n"
        "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        f"{len(entries)} beginbfchar\n{lines}\nendbfchar\nendcmap\n"
        "CMapName currentdict /CMap defineresource pop\nend\nend"
    ).encode()


def build_cidfont(path: Path, target: str) -> bool:
    try:
        from fontTools.fontBuilder import FontBuilder
        from fontTools.pens.ttGlyphPen import TTGlyphPen
    except ImportError:
        return False

    glyph_names: dict[str, str] = {}
    glyph_order = [".notdef"]
    for c in target:
        if c not in glyph_names:
            glyph_names[c] = f"g{len(glyph_order)}"
            glyph_order.append(glyph_names[c])

    box = TTGlyphPen(None)
    box.moveTo((50, 0))
    box.lineTo((50, 700))
    box.lineTo((450, 700))
    box.lineTo((450, 0))
    box.closePath()
    box_glyph = box.glyph()

    notdef = TTGlyphPen(None)
    notdef.moveTo((0, 0))
    notdef.lineTo((0, 10))
    notdef.lineTo((10, 10))
    notdef.lineTo((10, 0))
    notdef.closePath()

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({ord(c): name for c, name in glyph_names.items()})
    glyphs = {".notdef": notdef.glyph()}
    glyphs.update(dict.fromkeys(glyph_order[1:], box_glyph))
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(dict.fromkeys(glyph_order, (500, 0)))
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "NullmarkSynthetic", "styleName": "Regular"})
    fb.setupOS2()
    fb.setupPost()

    gids = {c: glyph_order.index(glyph_names[c]) for c in target}
    widths = {gids[c]: 500 for c in target}

    buf = io.BytesIO()
    fb.font.save(buf)
    font_bytes = buf.getvalue()

    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    page = b.reserve()

    font_file = b.add_stream(f"/Length1 {len(font_bytes)}".encode(), font_bytes)
    descriptor = b.add(
        (
            "<< /Type /FontDescriptor /FontName /NullmarkTestSubset /Flags 32 "
            "/FontBBox [0 -200 1000 1000] /ItalicAngle 0 /Ascent 900 /Descent -200 "
            f"/CapHeight 700 /StemV 80 /FontFile2 {font_file} 0 R >>"
        ).encode()
    )
    w_entries = " ".join(f"{gid} [{w}]" for gid, w in sorted(widths.items()))
    cidfont = b.add(
        (
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /NullmarkTestSubset "
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
            f"/FontDescriptor {descriptor} 0 R /DW 0 /W [{w_entries}] /CIDToGIDMap /Identity >>"
        ).encode()
    )
    tounicode = b.add_stream(b"", _tounicode_cmap({(gids[c], ord(c)) for c in target}))
    type0 = b.add(
        (
            "<< /Type /Font /Subtype /Type0 /BaseFont /NullmarkTestSubset "
            f"/Encoding /Identity-H /DescendantFonts [{cidfont} 0 R] /ToUnicode {tounicode} 0 R >>"
        ).encode()
    )
    hex_codes = "".join(f"{gids[c]:04X}" for c in target)
    content = b.add_stream(b"", f"BT /F1 24 Tf 72 700 Td <{hex_codes}> Tj ET".encode())
    b.set(page, _page_dict(pages, "F1", type0, content))
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML", xmp_bytes("Nullmark CID fixture")
    )
    info = b.add(info_dict_bytes("Nullmark CID fixture"))
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(
        catalog,
        f"<< /Type /Catalog /Pages {pages} 0 R /Metadata {metadata} 0 R >>".encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)
    return True


def build_hidden_cid_annotation(path: Path, target: str) -> bool:
    try:
        from fontTools import subset
        from fontTools.ttLib import TTFont
    except ImportError:
        return False
    if not SYSTEM_TTF.exists():
        return False

    font = TTFont(str(SYSTEM_TTF))
    opts = subset.Options()
    opts.retain_gids = True
    opts.notdef_outline = True
    opts.name_IDs = []
    opts.glyph_names = False
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(unicodes={ord(c) for c in target})
    subsetter.subset(font)

    cmap = font.getBestCmap()
    if not all(ord(c) in cmap for c in target):
        return False
    hmtx = font["hmtx"]
    upm = font["head"].unitsPerEm
    gids = {c: font.getGlyphID(cmap[ord(c)]) for c in target}
    widths = {gids[c]: round(hmtx[cmap[ord(c)]][0] * 1000 / upm) for c in target}

    buf = io.BytesIO()
    font.save(buf)
    font_bytes = buf.getvalue()

    b = PdfBuilder()
    catalog = b.reserve()
    pages = b.reserve()
    page = b.reserve()

    pfont = b.add(_helvetica())
    pcontent = b.add_stream(b"", BENIGN_BODY)

    font_file = b.add_stream(f"/Length1 {len(font_bytes)}".encode(), font_bytes)
    descriptor = b.add(
        (
            "<< /Type /FontDescriptor /FontName /NullmarkHiddenSubset /Flags 32 "
            "/FontBBox [0 -200 1000 1000] /ItalicAngle 0 /Ascent 900 /Descent -200 "
            f"/CapHeight 700 /StemV 80 /FontFile2 {font_file} 0 R >>"
        ).encode()
    )
    w_entries = " ".join(f"{gid} [{w}]" for gid, w in sorted(widths.items()))
    cidfont = b.add(
        (
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /NullmarkHiddenSubset "
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
            f"/FontDescriptor {descriptor} 0 R /DW 0 /W [{w_entries}] /CIDToGIDMap /Identity >>"
        ).encode()
    )
    type0 = b.add(
        (
            "<< /Type /Font /Subtype /Type0 /BaseFont /NullmarkHiddenSubset "
            f"/Encoding /Identity-H /DescendantFonts [{cidfont} 0 R] >>"
        ).encode()
    )
    hex_codes = "".join(f"{gids[c]:04X}" for c in target)
    ap_stream = b.add_stream(
        (
            "/Type /XObject /Subtype /Form /BBox [0 0 200 20] "
            f"/Resources << /Font << /F1 {type0} 0 R >> >>"
        ).encode(),
        f"BT /F1 12 Tf 2 4 Td <{hex_codes}> Tj ET".encode(),
    )
    annot = b.add(
        (
            "<< /Type /Annot /Subtype /FreeText /Rect [72 600 272 620] /F 2 "
            f"/AP << /N {ap_stream} 0 R >> /Contents () >>"
        ).encode()
    )
    b.set(
        page, _page_dict(pages, "F1", pfont, pcontent, extra=f" /Annots [{annot} 0 R]")
    )
    metadata = b.add_stream(
        b"/Type /Metadata /Subtype /XML",
        xmp_bytes("Nullmark hidden CID annotation fixture"),
    )
    info = b.add(info_dict_bytes("Nullmark hidden CID annotation fixture"))
    b.set(pages, f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    b.set(
        catalog,
        f"<< /Type /Catalog /Pages {pages} 0 R /Metadata {metadata} 0 R >>".encode(),
    )
    id1 = os.urandom(16).hex()
    b.write(path, catalog, info, id1, id1)
    return True


def generate_all(out_dir: Path, target: str = "OLDNAME") -> dict[str, Path | None]:
    out_dir.mkdir(parents=True, exist_ok=True)
    simple, multipage, cidfont = (
        out_dir / "simple.pdf",
        out_dir / "multipage.pdf",
        out_dir / "cidfont.pdf",
    )
    build_simple(simple, target)
    build_multipage(multipage, target)
    built = build_cidfont(cidfont, target)
    hidden_cid_annot = out_dir / "hidden_cid_annot.pdf"
    built_hidden_cid_annot = build_hidden_cid_annotation(hidden_cid_annot, target)
    surfaces: dict[str, Path | None] = {
        "simple": simple,
        "multipage": multipage,
        "cidfont": cidfont if built else None,
        "hidden_cid_annot": hidden_cid_annot if built_hidden_cid_annot else None,
    }
    builders = {
        "info": build_info_only,
        "xmp": build_xmp_only,
        "outline": build_outline_only,
        "annotation": build_annotation_only,
        "field": build_field_only,
        "embedded": build_embedded_only,
        "objstm": build_compressed_objstm,
        "appearance": build_appearance_stream_only,
        "name_value": build_name_value_only,
        "embedded_utf16le": build_embedded_utf16le_only,
    }
    for name, builder in builders.items():
        p = out_dir / f"{name}.pdf"
        builder(p, target)
        surfaces[name] = p
    return surfaces


if __name__ == "__main__":
    import sys

    out = generate_all(
        Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd() / "_generated"
    )
    for name, p in out.items():
        print(name, p if p else "SKIPPED (fontTools/system font unavailable)")
