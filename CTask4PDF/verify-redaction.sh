#!/usr/bin/env bash
# Builds the hardened CLI and runs tests/verify_redaction.py against it under
# sandbox/nullmark-cli.sb, so the gate proves a redaction succeeds inside that
# containment. pytest builds its own unhardened, unsandboxed CLI, so neither
# property is covered there.
#
# Both fixtures place the target at y=700 on a 792 pt page, far from the
# vertical centre: passing the stext quads through the inverse page transform a
# second time mirrors the /Redact annotation across that centre, and the target
# then survives.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
inc=/opt/homebrew/include
lib=/opt/homebrew/lib
work="$(mktemp -d "${TMPDIR:-/tmp}/t4verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Matches the justfile's `harden` flags; -O2 is what engages _FORTIFY_SOURCE.
cc -DT4_MAIN -std=c11 -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE \
        -I "$here/include" -I "$inc" -L "$lib" \
        -Wl,-rpath,"$lib" "$here/task4pdf.c" -lmupdf -o "$work/cli"

uv run --project "$here/../tests" --frozen python "$here/../tests/verify_redaction.py" "$work" "$here"
echo "verify-redaction: all cases passed"
