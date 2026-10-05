#!/usr/bin/env bash
# Regression guard for the redaction-placement fix in task4pdf.c.
#
# The stext quads collect_matches records are in transformed page space.
# pdf_set_annot_rect applies the inverse page transform itself, so the rect
# must be passed in that transformed space. An earlier version inverted the
# quads a second time by hand; that double inverse mirrored the /Redact
# annotation across the page's vertical centre, so any run not near centre
# survived redaction (residual > 0). This fixture places the target at y=700
# on a 792pt page (far from centre) to catch a re-introduction of that bug.
#
# Base-14 and 3-page cases run standalone here (no fontTools). The Type0/CID
# case and the byte-level Info/XMP/ID assertions live in the pytest harness
# (nullmark/tests/test_redactor.py): run that for full coverage.
#
# The CLI runs under sandbox/nullmark-cli.sb (network denied, filesystem limited
# to the two paths of the run) so this gate also confirms redaction still
# succeeds under that containment, not just that the Seatbelt profile builds.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
inc=/opt/homebrew/include
lib=/opt/homebrew/lib
work="$(mktemp -d "${TMPDIR:-/tmp}/t4verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Hardening flags per docs/standards/native-code.md. -O2 is required for
# _FORTIFY_SOURCE=2 to engage: without optimization the fortified libc variants
# are not substituted and the flag is inert.
cc -DT4_MAIN -std=c11 -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE \
        -I "$here/include" -I "$inc" -L "$lib" \
        -Wl,-rpath,"$lib" "$here/task4pdf.c" -lmupdf -o "$work/cli"

python3 - "$work" "$here" <<'PY'
import os, sys, subprocess, re
work, here = sys.argv[1], sys.argv[2]
sandbox_run = os.path.join(here, "sandbox", "run-sandboxed.sh")
def pdf_str(s): return b"(" + s.encode("latin-1") + b")"
def build(path, lines):
    objs = []
    def add(b): objs.append(b); return len(objs)
    xmp = (b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta '
           b'xmlns:x="adobe:ns:meta/"></x:xmpmeta><?xpacket end="w"?>')
    catalog = pages = None
    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    page_objs = []
    for txt in lines:
        c = (b"BT /F1 18 Tf 72 700 Td " + pdf_str(txt) + b" Tj ET")
        content = add(b"<< /Length %d >>\nstream\n" % len(c) + c + b"\nendstream")
        page_objs.append(("PAGE", content))
    meta = add(b"<< /Type /Metadata /Subtype /XML /Length %d >>\nstream\n" % len(xmp) + xmp + b"\nendstream")
    info = add(b"<< /Title (T4 verify) /Author (T4) /Producer (t4-verify) /CreationDate (D:20240101000000Z) >>")
    pages_num = len(objs) + 1 + len(page_objs) + 1  # placeholder, fixed below
    # assign page + pages + catalog object numbers explicitly
    page_nums = []
    for _, content in page_objs:
        page_nums.append(add(b"<< /Type /Page /Parent PAGES 0 R /MediaBox [0 0 612 792] "
                             b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>" % (font, content)))
    kids = b" ".join(b"%d 0 R" % p for p in page_nums)
    pages = add(b"<< /Type /Pages /Kids [" + kids + b"] /Count %d >>" % len(page_nums))
    catalog = add(b"<< /Type /Catalog /Pages %d 0 R /Metadata %d 0 R >>" % (pages, meta))
    objs = [o.replace(b"PAGES 0 R", b"%d 0 R" % pages) for o in objs]
    buf = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offs = []
    for i, body in enumerate(objs, 1):
        offs.append(len(buf)); buf += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    x = len(buf)
    buf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs)+1)
    for o in offs: buf += b"%010d 00000 n \n" % o
    idh = os.urandom(16).hex()
    buf += (b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R /ID [<%s> <%s>] >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs)+1, catalog, info, idh.encode(), idh.encode(), x))
    open(path, "wb").write(buf)

def clean(p):
    d = p + ".clean"
    subprocess.run(["mutool","clean","-d",p,d], check=True, capture_output=True)
    return open(d,"rb").read().decode("latin-1")
def text(p):
    return subprocess.run(["mutool","convert","-F","text","-o","-",p],
                          capture_output=True, text=True, check=True).stdout
def field(t, key):
    m = re.search(r"/%s\s*(\[.*?\]|\(.*?\)|<[0-9A-Fa-f]*>|/[^\s/>]+|\d+ \d+ R)" % key, t, re.DOTALL)
    return re.sub(r"\s+"," ", m.group(1)) if m else None

cases = {"simple": ["Statement for OLDNAME account"],
         "multipage": ["Page 1: OLDNAME here", "Page 2: OLDNAME here", "Page 3: OLDNAME here"]}
fail = 0
for name, lines in cases.items():
    src = os.path.join(work, name+".pdf"); out = os.path.join(work, name+".out.pdf")
    build(src, lines)
    r = subprocess.run([sandbox_run, os.path.join(work,"cli"), src, out, "OLDNAME", "NEWNAME"],
                       capture_output=True, text=True)
    raw = open(out,"rb").read()
    et = text(out); it = clean(src); ot = clean(out)
    checks = {
        "residual_absent": "OLDNAME" not in et,
        "replacement_present": "NEWNAME" in et,
        "single_EOF": raw.count(b"%%EOF") == 1,
        "no_Prev": b"/Prev" not in raw,
        "no_version": re.search(rb"MuPDF[ \t]+\d", raw) is None,
        "header_same": it[:8] == ot[:8],
        "ID_same": field(it,"ID") == field(ot,"ID"),
        "Info_same": field(it,"Producer") == field(ot,"Producer") and field(it,"Title")==field(ot,"Title"),
    }
    ok = all(checks.values())
    print(name, "PASS" if ok else "FAIL", "" if ok else checks, "| cli:", r.stdout.strip())
    fail |= not ok
sys.exit(1 if fail else 0)
PY
echo "verify-redaction: all cases passed"
