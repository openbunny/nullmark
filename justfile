# Nullmark's sole gate entry point. Run as `just <recipe>` from the repository
# root. `just check` runs every gate and reports every failure together,
# never stopping at the first. `just ci-check` installs dependencies first.
#
# Prerequisites, load-bearing for the recipes below:
#     mupdf      # CTask4PDF/task4pdf.c, verify-redaction.sh and tests/
#                # all build and link against it
#     cppcheck   # the `cppcheck` second-analyzer gate
#     llvm       # test-san, fuzz and coverage need LeakSanitizer, libFuzzer
#                # and llvm-cov; Apple's clang ships none of them on arm64
#                # macOS, so they use the LLVM toolchain.
#   Xcode 27.0, with `xcodegen` on PATH   # `build` generates and builds the
#                                          # .xcodeproj from project.yml
#   mise install   # actionlint, gitleaks, just, ruff, shellcheck, swiftlint,
#                   # xcodegen, zizmor and the rest of the pinned toolchain
set shell := ["bash", "-uc"]

# clang-format and clang-tidy ship in the LLVM prefix, which is not on
# PATH by default. Export it here so the fmt and lint gates resolve the same
# tools locally and in CI, where no step can adjust PATH for the just call.
export PATH := "/opt/homebrew/opt/llvm/bin:" + env('PATH')

llvm_bin := "/opt/homebrew/opt/llvm/bin"
mupdf_lib := "/opt/homebrew/lib/libmupdf.dylib"
mupdf_lock := "CTask4PDF/mupdf.lock"
# Hardening flags. -O2 is required for _FORTIFY_SOURCE=2 to engage: without
# optimization the fortified libc variants are not substituted and the flag
# is inert.
harden := "-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE"

gates := "fmt-check lint cppcheck typecheck mupdf-verify cli test xctest test-san fuzz coverage build swift-toolchain actions-lint actions-pin actions-audit secrets reuse forbidden-names tracked-outputs theme-check"

_default:
    @just --list

check: (_all gates)

ci-check: install
    just check

install:
    mise install
    cd tests && uv sync --frozen

# No runner here continues past a failing gate and reports every failure together.
_all gates:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=""
    for gate in {{ gates }}; do
        printf '\n\033[1m━━━ just %s\033[0m\n' "$gate"
        just "$gate" || failed="$failed $gate"
    done
    if [ -n "$failed" ]; then
        printf '\n\033[1;31mFAILED:\033[0m%s\n' "$failed" >&2
        exit 1
    fi
    printf '\n\033[1;32mall gates passed:\033[0m %s\n' "{{ gates }}"

fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t c_files < <(git ls-files '*.c' '*.h')
    (( ${#c_files[@]} > 0 ))
    clang-format -i "${c_files[@]}"
    swift format format --in-place --recursive App AppTests
    ruff format tests

fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t c_files < <(git ls-files '*.c' '*.h')
    (( ${#c_files[@]} > 0 ))
    clang-format --dry-run --Werror "${c_files[@]}"
    swift format lint --strict --recursive App AppTests
    ruff format --check tests

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t c_files < <(git ls-files '*.c')
    (( ${#c_files[@]} > 0 ))
    # MuPDF's headers include <setjmp.h> from the macOS SDK; without -isysroot
    # clang-tidy stops on the missing header before any check runs.
    clang-tidy --config-file=.clang-tidy "${c_files[@]}" -- -std=c11 \
        -isysroot "$(xcrun --show-sdk-path)" \
        -I CTask4PDF/include -I /opt/homebrew/include
    swiftlint lint --strict --config .swiftlint.yml
    ruff check tests
    mapfile -t sh_files < <(git ls-files '*.sh')
    (( ${#sh_files[@]} > 0 ))
    shellcheck "${sh_files[@]}"

cppcheck:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t c_files < <(git ls-files '*.c')
    (( ${#c_files[@]} > 0 ))
    cppcheck --enable=warning,performance,portability,style --std=c11 --language=c \
        --inline-suppr --suppressions-list=CTask4PDF/cppcheck-suppressions.txt \
        --error-exitcode=2 \
        -I CTask4PDF/include -I /opt/homebrew/include "${c_files[@]}"

# Records the linked MuPDF's installed version and the sha256 of the resolved
# libmupdf.dylib into CTask4PDF/mupdf.lock. See README.md for why this pin
# exists. Run after a reviewed MuPDF upgrade to move the pin forward.
mupdf-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    test -e {{ mupdf_lib }} || { echo "mupdf-lock: {{ mupdf_lib }} not found" >&2; exit 1; }
    resolved="$(readlink -f {{ mupdf_lib }})"
    version="$(brew list --versions mupdf | awk '{print $2}')"
    test -n "$version" || { echo "mupdf-lock: mupdf version unknown" >&2; exit 1; }
    sha="$(shasum -a 256 "$resolved" | awk '{print $1}')"
    printf 'version=%s\nsha256=%s\n' "$version" "$sha" > {{ mupdf_lock }}
    echo "mupdf-lock: recorded mupdf $version ($sha)"

# Verifies the linked libmupdf.dylib against CTask4PDF/mupdf.lock. A checkout
# with no lock recorded yet passes with a notice, so a fresh clone never fails
# here; once a lock is recorded, a version or hash mismatch fails closed.
mupdf-verify:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f {{ mupdf_lock }} ]; then
        echo "mupdf-verify: no {{ mupdf_lock }} recorded; run 'just mupdf-lock' to pin the linked MuPDF. Skipping." >&2
        exit 0
    fi
    test -e {{ mupdf_lib }} || { echo "mupdf-verify: {{ mupdf_lib }} not found" >&2; exit 1; }
    resolved="$(readlink -f {{ mupdf_lib }})"
    version="$(brew list --versions mupdf | awk '{print $2}')"
    sha="$(shasum -a 256 "$resolved" | awk '{print $1}')"
    want_version="$(sed -n 's/^version=//p' {{ mupdf_lock }})"
    want_sha="$(sed -n 's/^sha256=//p' {{ mupdf_lock }})"
    if [ "$version" != "$want_version" ] || [ "$sha" != "$want_sha" ]; then
        echo "mupdf-verify: linked mupdf $version ($sha) does not match locked $want_version ($want_sha)" >&2
        echo "mupdf-verify: if this upgrade was reviewed for its CVE delta, run 'just mupdf-lock' to move the pin forward" >&2
        exit 1
    fi
    echo "mupdf-verify: linked mupdf $version matches locked hash"

typecheck:
    #!/usr/bin/env bash
    set -euo pipefail
    # mypy runs inside tests/.venv through uv run, whose interpreter carries
    # pytest and fontTools. A mypy outside that environment has neither, which
    # turned every @pytest.fixture into an untyped-decorator error and left the
    # gate reporting noise rather than real type findings. Run from tests/ so
    # tests/pyproject.toml's [tool.mypy] (strict, files, fontTools override) is
    # the config in effect.
    ( cd tests && uv run --frozen mypy . )

test:
    #!/usr/bin/env bash
    set -euo pipefail
    # mupdf is a documented prerequisite for this recipe (see the header
    # comment above); NULLMARK_REQUIRE_MUPDF turns test_redactor.py's own skip
    # into a hard failure so this gate cannot go green with the whole
    # module unexercised. pytest runs inside tests/.venv through uv run, which
    # carries the pinned pytest, hypothesis and fontTools from uv.lock.
    ( cd tests && NULLMARK_REQUIRE_MUPDF=1 uv run --frozen python -m pytest . -v )
    ./CTask4PDF/verify-redaction.sh

xctest:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodegen generate
    xcodebuild test -project Nullmark.xcodeproj -scheme Nullmark CODE_SIGNING_ALLOWED=NO

# The hardened -DT4_MAIN CLI build with warnings-as-errors. Fails loudly on any
# warning; the built binary is then run once under CTask4PDF/sandbox/nullmark-cli.sb
# (network denied, filesystem limited to the input/output paths of this one run)
# to confirm the Seatbelt profile still lets a normal redaction succeed.
cli:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkcli.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    clang -DT4_MAIN -std=c11 -Wall -Wextra -Wpedantic -Werror {{ harden }} \
        -isysroot "$(xcrun --show-sdk-path)" \
        -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/task4pdf.c -lmupdf -o "$out/nullmark-cli"
    echo "cli: hardened -DT4_MAIN build succeeded"
    uv run --project tests --frozen python tests/fixtures/generate.py "$out/fx" >/dev/null
    log="$out/sandboxed.log"
    CTask4PDF/sandbox/run-sandboxed.sh "$out/nullmark-cli" "$out/fx/simple.pdf" \
        "$out/simple.out.pdf" OLDNAME NEWNAME >"$log" 2>&1
    if ! grep -qE 'rc=0 .*residual=0' "$log"; then
        echo "cli: sandboxed run did not report a clean redaction:" >&2
        cat "$log" >&2
        exit 1
    fi
    test -f "$out/simple.out.pdf"
    echo "cli: sandboxed run (Seatbelt profile, network denied) produced a clean redaction"

# AddressSanitizer + UndefinedBehaviorSanitizer + LeakSanitizer over the CLI run
# on the generated fixtures. The C core's own code must be clean; leaks originating in
# non-instrumented libmupdf are filtered by the mupdf-scoped LSan suppressions.
test-san:
    #!/usr/bin/env bash
    set -euo pipefail
    test -x {{ llvm_bin }}/clang || { echo "test-san needs the LLVM toolchain" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarksan.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    uv run --project tests --frozen python tests/fixtures/generate.py "$work/fx" >/dev/null
    shopt -s nullglob
    fixtures=("$work"/fx/*.pdf)
    test "${#fixtures[@]}" -gt 0
    {{ llvm_bin }}/clang -DT4_MAIN -std=c11 -g -O1 \
        -fsanitize=address,undefined -fno-sanitize-recover=undefined \
        -fno-omit-frame-pointer -isysroot "$sdk" \
        -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/task4pdf.c -lmupdf -o "$work/cli_san"
    export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0"
    export LSAN_OPTIONS="suppressions=$PWD/CTask4PDF/lsan-suppressions.txt"
    export UBSAN_OPTIONS="print_stacktrace=1"
    rc=0
    for f in "${fixtures[@]}"; do
        log="$work/$(basename "$f").log"
        # The CLI exits non-zero on a fixture whose target survives on an
        # unrewritten surface (fail-closed); that is expected, so only a
        # sanitizer signature in the output fails this gate.
        "$work/cli_san" "$f" "$work/$(basename "$f").out" OLDNAME NEWNAME >"$log" 2>&1 || true
        if grep -qE 'runtime error:|ERROR: AddressSanitizer|LeakSanitizer: detected memory leaks' "$log"; then
            echo "test-san: sanitizer finding on $(basename "$f"):" >&2
            cat "$log" >&2
            rc=1
        fi
    done
    test "$rc" -eq 0
    echo "test-san: ASan/UBSan/LSan clean over ${#fixtures[@]} fixtures"

# Bounded libFuzzer campaign against t4_replace, the entry point that ingests an
# untrusted PDF. Seeds from the committed corpus; a crash fails the gate and its
# reproducer is preserved. Fix a crash in task4pdf.c, never by weakening the
# harness.
fuzz:
    #!/usr/bin/env bash
    set -euo pipefail
    test -x {{ llvm_bin }}/clang || { echo "fuzz needs the LLVM toolchain" >&2; exit 1; }
    corpus=CTask4PDF/fuzz/corpus
    test -n "$(ls -A "$corpus" 2>/dev/null)" || { echo "fuzz: seed corpus $corpus is empty" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkfuzz.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    {{ llvm_bin }}/clang -std=c11 -g -O1 \
        -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer \
        -isysroot "$sdk" -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/fuzz/fuzz_t4_replace.c CTask4PDF/task4pdf.c -lmupdf -o "$work/fuzz_t4"
    # Run over a copy so units libFuzzer discovers do not pollute the committed
    # seed corpus.
    mkdir -p "$work/corpus" "$work/artifacts"
    cp "$corpus"/* "$work/corpus"/
    export LSAN_OPTIONS="suppressions=$PWD/CTask4PDF/lsan-suppressions.txt"
    set +e
    "$work/fuzz_t4" "$work/corpus" -max_total_time=60 -rss_limit_mb=4096 \
        -artifact_prefix="$work/artifacts/"
    fz=$?
    set -e
    if [ "$fz" -ne 0 ]; then
        dest="$PWD/CTask4PDF/fuzz/crash-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$dest"
        cp "$work"/artifacts/* "$dest"/ 2>/dev/null || true
        echo "fuzz: crash found; reproducer(s) saved under $dest" >&2
        exit 1
    fi
    echo "fuzz: bounded 60s campaign completed with no crash"

# llvm-cov region/line/function report for the C core. Report only, no
# threshold enforced.
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    test -x {{ llvm_bin }}/clang || { echo "coverage needs the LLVM toolchain" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkcov.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    uv run --project tests --frozen python tests/fixtures/generate.py "$work/fx" >/dev/null
    shopt -s nullglob
    fixtures=("$work"/fx/*.pdf)
    test "${#fixtures[@]}" -gt 0
    {{ llvm_bin }}/clang -DT4_MAIN -std=c11 -g -O0 \
        -fprofile-instr-generate -fcoverage-mapping -isysroot "$sdk" \
        -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/task4pdf.c -lmupdf -o "$work/cli_cov"
    mkdir -p "$work/raw"
    for f in "${fixtures[@]}"; do
        LLVM_PROFILE_FILE="$work/raw/$(basename "$f").profraw" \
            "$work/cli_cov" "$f" "$work/$(basename "$f").out" OLDNAME NEWNAME >/dev/null 2>&1 || true
    done
    {{ llvm_bin }}/llvm-profdata merge -sparse "$work"/raw/*.profraw -o "$work/nullmark.profdata"
    {{ llvm_bin }}/llvm-cov report "$work/cli_cov" \
        -instr-profile="$work/nullmark.profdata" CTask4PDF/task4pdf.c

build:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodegen generate
    xcodebuild build -project Nullmark.xcodeproj -scheme Nullmark \
        CODE_SIGNING_ALLOWED=NO

# The Xcode major.minor in .xcode-version is part of the gate: swift-format
# output depends on the toolchain.
swift-toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f .xcode-version || { echo "swift-toolchain: .xcode-version is missing" >&2; exit 1; }
    want=$(tr -d '[:space:]' < .xcode-version)
    got=$(xcodebuild -version | awk 'NR==1 {print $2}' | cut -d. -f1,2)
    if [ "$got" != "$want" ]; then
        printf 'swift-toolchain: Xcode %s is selected, .xcode-version requires %s.\n' "$got" "$want" >&2
        exit 1
    fi

actions-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    test -n "$files"
    echo "$files" | xargs actionlint

# Every third-party uses: is pinned to a full 40- or 64-hex commit SHA.
actions-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    test -n "$files"
    bad=""
    for f in $files; do
        while IFS= read -r line; do
            case "$line" in
                *uses:*@* ) ;;
                *uses:\ docker/* ) ;;
                *uses:\ ./* ) ;;
                *uses:* )
                    echo "actions-pin: unpinned action in $f: $line" >&2
                    bad=1
                    ;;
            esac
            case "$line" in
                *uses:*@[0-9a-f]* )
                    ref="${line##*@}"
                    ref="${ref%% *}"
                    case "$ref" in
                        ????????????????????????????????????????* ) ;;
                        * )
                            echo "actions-pin: short ref in $f: $line" >&2
                            bad=1
                            ;;
                    esac
                    ;;
            esac
        done < "$f"
    done
    test -z "$bad"

actions-audit:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    test -n "$files"
    echo "$files" | xargs zizmor --offline --pedantic

secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    gitleaks detect --source . --verbose

reuse:
    #!/usr/bin/env bash
    set -euo pipefail
    reuse lint

# Fails when any origin branding remains. Word-boundary matching keeps the
# carried C identifiers (CTask4PDF, task4pdf, t4_replace, T4Result, TASK4_)
# green: none of them has a boundary inside the token.
forbidden-names:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files --cached --others --exclude-standard | grep -v -e '^tests/uv.lock$')
    test -n "$files"
    if echo "$files" | xargs grep -nE '\bsm\.fiona\b|\btask4\b|\btouch\b|\bTouch\b|\bnotouch\b|\bNoTouch\b'; then
        echo "forbidden-names: origin branding is present" >&2
        exit 1
    fi
    echo "forbidden-names: no origin branding"

# Build output belongs in .gitignore; a path here means it would be committed.
tracked-outputs:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files --cached --others --exclude-standard)
    test -n "$files" || { echo "tracked-outputs: no files to scan" >&2; exit 1; }
    if echo "$files" | grep -E '^build/|\.xcodeproj/|\.DS_Store$'; then
        echo "tracked-outputs: build output is not ignored" >&2
        exit 1
    fi

# No design token literal outside the theme package: no DS namespace, no hex
# colour, no inline Color/Font constructors in App/; the icon SVG uses only
# OpenBunny token colours and the committed icon set is complete.
theme-check:
    #!/usr/bin/env bash
    set -euo pipefail
    swift_files=$(git ls-files 'App/*.swift' 'App/**/*.swift')
    test -n "$swift_files"
    bad=""
    if echo "$swift_files" | xargs grep -nE 'DS\.|#[0-9a-fA-F]{3,}|Color\(\.|Font\.(system|custom)' | grep -v 'Color\.clear'; then
        echo "theme-check: design token literal outside the theme package" >&2
        bad=1
    fi
    grep -qIE 'f2c6d9|100e14|f7f2ef|9a93a3' App/Assets/AppIcon.svg && {
        echo "theme-check: AppIcon.svg still carries origin colours" >&2
        bad=1
    } || true
    test -f App/Assets.xcassets/AppIcon.appiconset/Contents.json
    test -z "$bad"
