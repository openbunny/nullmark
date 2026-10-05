#!/usr/bin/env bash
# Runs the nullmark CLI under nullmark-cli.sb: network denied, filesystem access
# limited to the input PDF (read) and the output PDF (read/write). sandbox-exec
# takes the profile's parameters only as -D arguments, so this wrapper exists to
# resolve each path to the form the kernel presents to the profile.
#
# Usage: run-sandboxed.sh <cli-binary> <in.pdf> <out.pdf> <find> <replace>
# The exit code and output are the CLI's own; a profile violation surfaces as
# the CLI's I/O failure or a dyld load failure, not a distinct error from here.
set -euo pipefail

if (( $# != 5 )); then
    echo "usage: $0 <cli-binary> <in.pdf> <out.pdf> <find> <replace>" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd -P)"
bin=$1 in=$2 out=$3 find=$4 replace=$5

# A `(literal ...)` rule matches the path the kernel resolves at the syscall,
# which on macOS is under /private while $TMPDIR and /tmp are symlinks to it; an
# unresolved path matches nothing and the CLI is denied. Only the directory is
# resolved, because the output file does not exist until the CLI creates it.
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
