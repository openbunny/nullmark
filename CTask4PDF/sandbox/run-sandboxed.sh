#!/usr/bin/env bash
# Runs the nullmark-cli entry point under the Seatbelt profile in this
# directory: network denied, filesystem access limited to the input PDF
# (read) and the output PDF (read/write). See nullmark-cli.sb for why.
#
# Usage: run-sandboxed.sh <cli-binary> <in.pdf> <out.pdf> <find> <replace>
# Exit code and stdout/stderr are the wrapped CLI's; a profile violation
# surfaces as the CLI's own I/O failure (or a dyld load failure), not a
# distinct error from this wrapper.
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <cli-binary> <in.pdf> <out.pdf> <find> <replace>" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd -P)"
bin=$1 in=$2 out=$3 find=$4 replace=$5

# Resolves to the real, symlink-free path of the containing directory (its
# leaf need not exist yet: OUT_PATH is created by the CLI, not by us) and
# reattaches the leaf name as given. nullmark-cli.sb matches a `(literal ...)`
# path against what the kernel resolves at the syscall boundary — on macOS
# that is under /private, while $TMPDIR and /tmp are symlinks to it — so an
# unresolved path here would silently fail to match and the CLI would be
# denied the very access this profile means to grant it.
realdir_path() {
    local dir
    dir="$(cd "$(dirname "$1")" && pwd -P)"
    printf '%s/%s\n' "$dir" "$(basename "$1")"
}
bin="$(realdir_path "$bin")"
in="$(realdir_path "$in")"
out="$(realdir_path "$out")"

exec sandbox-exec -f "$here/nullmark-cli.sb" \
    -D BIN_PATH="$bin" -D IN_PATH="$in" -D OUT_PATH="$out" \
    -- "$bin" "$in" "$out" "$find" "$replace"
