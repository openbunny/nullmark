# Prerequisites outside mise.toml: Xcode, and mupdf, llvm and cppcheck under
# /opt/homebrew. Apple's clang ships no libFuzzer or LeakSanitizer.
set shell := ["bash", "-euo", "pipefail", "-c"]

export PATH := "/opt/homebrew/opt/llvm/bin:" + env("PATH")
export SDKROOT := `xcrun --show-sdk-path`

link_mupdf := "-ICTask4PDF/include -I/opt/homebrew/include -L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib -lmupdf"
fuzz_sources := "CTask4PDF/fuzz/fuzz_t4_replace.c CTask4PDF/task4pdf.c"

check: fmt-check lint typecheck test xctest fuzz coverage actions secrets reuse

ci-check: install check

install:
    mise install
    uv sync --frozen --project tests
    lefthook install

fmt:
    git ls-files '*.c' '*.h' | xargs clang-format -i
    swift format format --in-place --recursive App AppTests
    ruff format tests

fmt-check:
    git ls-files '*.c' '*.h' | xargs clang-format --dry-run --Werror
    swift format lint --strict --recursive App AppTests
    ruff format --check tests

lint:
    git ls-files '*.c' | xargs clang-tidy --quiet
    git ls-files '*.c' | xargs cppcheck --std=c11 --language=c --enable=warning,performance,portability,style --inline-suppr --suppressions-list=CTask4PDF/cppcheck-suppressions.txt --error-exitcode=2 -DT4_MAIN -ICTask4PDF/include -I/opt/homebrew/include
    swiftlint lint --strict
    ruff check tests

typecheck:
    cd tests && uv run --frozen mypy .

test:
    cd tests && uv run --frozen pytest

xctest:
    xcodegen generate
    xcodebuild test -project Nullmark.xcodeproj -scheme Nullmark CODE_SIGNING_ALLOWED=NO

# The fuzz build is also the sanitizer gate: ASan, UBSan and LeakSanitizer
# together over the seed corpus and every input libFuzzer derives from it.
# -rss_limit_mb=0 stops libFuzzer starting its RSS monitor thread, which
# LeakSanitizer reports as a leak at exit; -malloc_limit_mb keeps the
# allocation cap the RSS limit otherwise sets.
fuzz:
    mkdir -p build/fuzz-corpus
    clang -std=c11 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined {{ fuzz_sources }} {{ link_mupdf }} -o build/fuzz
    ASAN_OPTIONS=detect_leaks=1 build/fuzz build/fuzz-corpus CTask4PDF/fuzz/corpus -max_total_time=60 -rss_limit_mb=0 -malloc_limit_mb=4096 -artifact_prefix=CTask4PDF/fuzz/

coverage:
    clang -std=c11 -fprofile-instr-generate -fcoverage-mapping -fsanitize=fuzzer {{ fuzz_sources }} {{ link_mupdf }} -o build/coverage
    LLVM_PROFILE_FILE=build/coverage.profraw build/coverage -runs=0 CTask4PDF/fuzz/corpus
    llvm-profdata merge -sparse build/coverage.profraw -o build/coverage.profdata
    llvm-cov report build/coverage -instr-profile=build/coverage.profdata CTask4PDF/task4pdf.c

actions:
    actionlint
    zizmor --offline --pedantic .

secrets:
    gitleaks git

reuse:
    reuse lint
