# Nullmark's gate entry point. `just check` runs every gate in `gates` and
# reports every failure together; `just ci-check` installs dependencies first.
#
# Prerequisites outside mise.toml:
#   mupdf     task4pdf.c, verify-redaction.sh and tests/ build and link against it.
#   cppcheck  the `cppcheck` gate.
#   llvm      test-san, fuzz and coverage need LeakSanitizer, libFuzzer and
#             llvm-cov, which Apple's clang does not ship on arm64 macOS.
#   Xcode     at the version .xcode-version names; `swift-toolchain` checks it.
set shell := ["bash", "-uc"]

# clang-format and clang-tidy ship in the LLVM prefix, which is not on PATH by
# default, and no CI step can adjust PATH for the just call.
export PATH := "/opt/homebrew/opt/llvm/bin:" + env('PATH')

llvm_bin := "/opt/homebrew/opt/llvm/bin"
mupdf_lib := "/opt/homebrew/lib/libmupdf.dylib"
mupdf_lock := "CTask4PDF/mupdf.lock"
# -O2 is required for _FORTIFY_SOURCE=2 to engage: without optimization the
# fortified libc variants are not substituted and the flag is inert.
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

# -e is left off so every gate runs and every failure is reported together.
_all gates:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for gate in {{ gates }}; do
        printf '\n\033[1m━━━ just %s\033[0m\n' "$gate"
        just "$gate" || failed+=("$gate")
    done
    if (( ${#failed[@]} > 0 )); then
        printf '\n\033[1;31mFAILED:\033[0m %s\n' "${failed[*]}" >&2
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
    clang-tidy --config-file=.clang-tidy "${c_files[@]}" -- -DT4_MAIN -std=c11 \
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

# Records the linked MuPDF's version and the sha256 of the resolved
# libmupdf.dylib in CTask4PDF/mupdf.lock (README.md, "MuPDF version pin"). Run
# after a reviewed MuPDF upgrade to move the pin forward.
mupdf-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -e {{ mupdf_lib }} ]] || { echo "mupdf-lock: {{ mupdf_lib }} not found" >&2; exit 1; }
    resolved="$(readlink -f {{ mupdf_lib }})"
    version="$(brew list --versions mupdf | awk '{print $2}')"
    [[ -n $version ]] || { echo "mupdf-lock: brew reports no installed mupdf version" >&2; exit 1; }
    sha="$(shasum -a 256 "$resolved" | awk '{print $1}')"
    printf 'version=%s\nsha256=%s\n' "$version" "$sha" > {{ mupdf_lock }}
    echo "mupdf-lock: recorded mupdf $version ($sha)"

mupdf-verify:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f {{ mupdf_lock }} ]] || { echo "mupdf-verify: {{ mupdf_lock }} is missing; run 'just mupdf-lock' after reviewing the linked MuPDF" >&2; exit 1; }
    [[ -e {{ mupdf_lib }} ]] || { echo "mupdf-verify: {{ mupdf_lib }} not found" >&2; exit 1; }
    resolved="$(readlink -f {{ mupdf_lib }})"
    version="$(brew list --versions mupdf | awk '{print $2}')"
    sha="$(shasum -a 256 "$resolved" | awk '{print $1}')"
    want_version="$(sed -n 's/^version=//p' {{ mupdf_lock }})"
    want_sha="$(sed -n 's/^sha256=//p' {{ mupdf_lock }})"
    if [[ $version != "$want_version" || $sha != "$want_sha" ]]; then
        echo "mupdf-verify: linked mupdf $version ($sha) does not match locked $want_version ($want_sha)" >&2
        echo "mupdf-verify: if this upgrade was reviewed for its CVE delta, run 'just mupdf-lock' to move the pin forward" >&2
        exit 1
    fi
    echo "mupdf-verify: linked mupdf $version matches locked hash"

# Runs from tests/ so tests/pyproject.toml's [tool.mypy] applies, inside the
# uv environment that carries pytest and fontTools: outside it, every
# @pytest.fixture is reported as an untyped decorator.
typecheck:
    #!/usr/bin/env bash
    set -euo pipefail
    ( cd tests && uv run --frozen mypy . )

# NULLMARK_REQUIRE_MUPDF turns the redactor modules' missing-MuPDF skip into a
# failure, so this gate cannot pass with those modules unexercised.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    ( cd tests && NULLMARK_REQUIRE_MUPDF=1 uv run --frozen python -m pytest . -v )
    ./CTask4PDF/verify-redaction.sh

# xcodebuild passes a run that discovers no tests, so the result bundle's test
# count is checked.
xctest:
    #!/usr/bin/env bash
    set -euo pipefail
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkxctest.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    xcodegen generate
    xcodebuild test -project Nullmark.xcodeproj -scheme Nullmark CODE_SIGNING_ALLOWED=NO \
        -resultBundlePath "$work/result.xcresult"
    summary="$(xcrun xcresulttool get test-results summary --path "$work/result.xcresult")"
    if ! grep -qE '"totalTestCount" *: *[1-9]' <<<"$summary"; then
        echo "xctest: the result bundle reports no tests run:" >&2
        echo "$summary" >&2
        exit 1
    fi

# Builds the -DT4_MAIN CLI with the hardening flags and warnings as errors,
# then runs it once under CTask4PDF/sandbox/nullmark-cli.sb to confirm the
# Seatbelt profile still lets a normal redaction succeed.
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
    [[ -f $out/simple.out.pdf ]]
    echo "cli: sandboxed run (Seatbelt profile, network denied) produced a clean redaction"

# AddressSanitizer, UndefinedBehaviorSanitizer and LeakSanitizer over the CLI
# run on every generated fixture. No leak is suppressed: LeakSanitizer matches a
# suppression against any frame of the allocation stack, so a pattern naming
# libmupdf would also hide a C-core leak allocated through fz_malloc.
test-san:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -x {{ llvm_bin }}/clang ]] || { echo "test-san: {{ llvm_bin }}/clang not found; install llvm" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarksan.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    uv run --project tests --frozen python tests/fixtures/generate.py "$work/fx" >/dev/null
    shopt -s nullglob
    fixtures=("$work"/fx/*.pdf)
    (( ${#fixtures[@]} > 0 ))
    {{ llvm_bin }}/clang -DT4_MAIN -std=c11 -g -O1 \
        -fsanitize=address,undefined -fno-sanitize-recover=undefined \
        -fno-omit-frame-pointer -isysroot "$sdk" \
        -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/task4pdf.c -lmupdf -o "$work/cli_san"
    export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0"
    export UBSAN_OPTIONS="print_stacktrace=1"
    rc=0
    for f in "${fixtures[@]}"; do
        log="$work/${f##*/}.log"
        # The CLI exits non-zero on every fail-closed fixture, so only a
        # sanitizer signature in its output fails this gate.
        "$work/cli_san" "$f" "$work/${f##*/}.out" OLDNAME NEWNAME >"$log" 2>&1 || true
        if grep -qE 'runtime error:|ERROR: AddressSanitizer|LeakSanitizer: detected memory leaks' "$log"; then
            echo "test-san: sanitizer finding on ${f##*/}:" >&2
            cat "$log" >&2
            rc=1
        fi
    done
    (( rc == 0 ))
    echo "test-san: ASan/UBSan/LSan clean over ${#fixtures[@]} fixtures"

# Bounded libFuzzer campaign against t4_replace, seeded from the committed
# corpus. A crash fails the gate and its reproducer is kept under
# CTask4PDF/fuzz/crash-*. No leak is suppressed, for the reason test-san states.
fuzz:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -x {{ llvm_bin }}/clang ]] || { echo "fuzz: {{ llvm_bin }}/clang not found; install llvm" >&2; exit 1; }
    shopt -s nullglob
    seeds=(CTask4PDF/fuzz/corpus/*)
    (( ${#seeds[@]} > 0 )) || { echo "fuzz: seed corpus CTask4PDF/fuzz/corpus is empty" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkfuzz.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    {{ llvm_bin }}/clang -std=c11 -g -O1 \
        -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer \
        -isysroot "$sdk" -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/fuzz/fuzz_t4_replace.c CTask4PDF/task4pdf.c -lmupdf -o "$work/fuzz_t4"
    # libFuzzer writes the inputs it discovers into its corpus directory, so it
    # runs over a copy of the committed seeds.
    mkdir -p "$work/corpus" "$work/artifacts"
    cp "${seeds[@]}" "$work/corpus"/
    fz=0
    "$work/fuzz_t4" "$work/corpus" -max_total_time=60 -rss_limit_mb=4096 \
        -artifact_prefix="$work/artifacts/" || fz=$?
    if (( fz != 0 )); then
        dest="$PWD/CTask4PDF/fuzz/crash-$(date +%Y%m%d-%H%M%S)"
        artifacts=("$work"/artifacts/*)
        if (( ${#artifacts[@]} > 0 )); then
            mkdir -p "$dest"
            cp "${artifacts[@]}" "$dest"/
            echo "fuzz: exit $fz; reproducers saved under $dest" >&2
        else
            echo "fuzz: exit $fz with no reproducer written; see the output above" >&2
        fi
        exit 1
    fi
    echo "fuzz: bounded 60s campaign completed with no crash"

# Reports llvm-cov region, line and function coverage for the C core. No floor
# is enforced.
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -x {{ llvm_bin }}/clang ]] || { echo "coverage: {{ llvm_bin }}/clang not found; install llvm" >&2; exit 1; }
    sdk="$(xcrun --show-sdk-path)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/nullmarkcov.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    uv run --project tests --frozen python tests/fixtures/generate.py "$work/fx" >/dev/null
    shopt -s nullglob
    fixtures=("$work"/fx/*.pdf)
    (( ${#fixtures[@]} > 0 ))
    {{ llvm_bin }}/clang -DT4_MAIN -std=c11 -g -O0 \
        -fprofile-instr-generate -fcoverage-mapping -isysroot "$sdk" \
        -I CTask4PDF/include -I /opt/homebrew/include \
        -L /opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib \
        CTask4PDF/task4pdf.c -lmupdf -o "$work/cli_cov"
    mkdir -p "$work/raw"
    for f in "${fixtures[@]}"; do
        # Fail-closed fixtures exit non-zero by design; only their profile matters.
        LLVM_PROFILE_FILE="$work/raw/${f##*/}.profraw" \
            "$work/cli_cov" "$f" "$work/${f##*/}.out" OLDNAME NEWNAME >/dev/null 2>&1 || true
    done
    profiles=("$work"/raw/*.profraw)
    (( ${#profiles[@]} == ${#fixtures[@]} ))
    {{ llvm_bin }}/llvm-profdata merge -sparse "${profiles[@]}" -o "$work/nullmark.profdata"
    {{ llvm_bin }}/llvm-cov report "$work/cli_cov" \
        -instr-profile="$work/nullmark.profdata" CTask4PDF/task4pdf.c

build:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodegen generate
    xcodebuild build -project Nullmark.xcodeproj -scheme Nullmark \
        CODE_SIGNING_ALLOWED=NO

# swift-format output depends on the toolchain, so the Xcode major.minor in
# .xcode-version is part of the gate.
swift-toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f .xcode-version ]] || { echo "swift-toolchain: .xcode-version is missing" >&2; exit 1; }
    want=$(tr -d '[:space:]' < .xcode-version)
    got=$(xcodebuild -version | awk 'NR==1 {print $2}' | cut -d. -f1,2)
    if [[ $got != "$want" ]]; then
        printf 'swift-toolchain: Xcode %s is selected, .xcode-version requires %s.\n' "$got" "$want" >&2
        exit 1
    fi

actions-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    (( ${#files[@]} > 0 ))
    actionlint "${files[@]}"

# Every `uses:` is a local path or a full 40- or 64-hex commit SHA followed by
# a `# <version>` comment, the shape languages/github-actions.md requires.
actions-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    (( ${#files[@]} > 0 ))
    pinned='uses:[[:space:]]+(\./|[^@[:space:]]+@[0-9a-f]{40}([0-9a-f]{24})?[[:space:]]+#[[:space:]]*[^[:space:]])'
    bad=0
    while IFS= read -r hit; do
        [[ $hit =~ $pinned ]] && continue
        echo "actions-pin: not a local path or a SHA with a version comment: $hit" >&2
        bad=1
    done < <(grep -nH 'uses:' "${files[@]}")
    (( bad == 0 ))

actions-audit:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
    (( ${#files[@]} > 0 ))
    zizmor --offline --pedantic "${files[@]}"

secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    gitleaks detect --source . --verbose

reuse:
    #!/usr/bin/env bash
    set -euo pipefail
    reuse lint

# Fails when origin branding remains. Word-boundary matching keeps the carried
# C identifiers (CTask4PDF, task4pdf, t4_replace, T4Result, TASK4_) green: none
# of them has a boundary inside the token.
forbidden-names:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(git ls-files --cached --others --exclude-standard | grep -vx 'tests/uv.lock')
    (( ${#files[@]} > 0 ))
    if grep -nE '\bsm\.fiona\b|\btask4\b|\btouch\b|\bTouch\b|\bnotouch\b|\bNoTouch\b' "${files[@]}"; then
        echo "forbidden-names: origin branding is present" >&2
        exit 1
    fi
    echo "forbidden-names: no origin branding"

# Build output belongs in .gitignore; a path listed here would be committed.
tracked-outputs:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git ls-files --cached --others --exclude-standard)
    [[ -n $files ]] || { echo "tracked-outputs: no files to scan" >&2; exit 1; }
    if grep -E '^build/|\.xcodeproj/|\.DS_Store$' <<<"$files"; then
        echo "tracked-outputs: build output is not ignored" >&2
        exit 1
    fi

# No design token literal outside the theme package: no DS namespace, no hex
# colour and no inline Color/Font constructor in App/. The icon SVG uses only
# OpenBunny token colours, and the committed icon set is complete.
theme-check:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t swift_files < <(git ls-files 'App/*.swift' 'App/**/*.swift')
    (( ${#swift_files[@]} > 0 ))
    bad=0
    if grep -nE 'DS\.|#[0-9a-fA-F]{3,}|Color\(\.|Font\.(system|custom)' "${swift_files[@]}" | grep -v 'Color\.clear'; then
        echo "theme-check: design token literal outside the theme package" >&2
        bad=1
    fi
    if grep -qIE 'f2c6d9|100e14|f7f2ef|9a93a3' App/Assets/AppIcon.svg; then
        echo "theme-check: AppIcon.svg still carries origin colours" >&2
        bad=1
    fi
    [[ -f App/Assets.xcassets/AppIcon.appiconset/Contents.json ]]
    (( bad == 0 ))
