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
# (tests/test_redactor.py): run that for full coverage. The fixture builder
# and the per-case checks are tests/verify_redaction.py.
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

# Hardening flags match the justfile's `harden` set. -O2 is required for
# _FORTIFY_SOURCE=2 to engage: without optimization the fortified libc variants
# are not substituted and the flag is inert.
cc -DT4_MAIN -std=c11 -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE \
        -I "$here/include" -I "$inc" -L "$lib" \
        -Wl,-rpath,"$lib" "$here/task4pdf.c" -lmupdf -o "$work/cli"

python3 "$here/../tests/verify_redaction.py" "$work" "$here"
echo "verify-redaction: all cases passed"
