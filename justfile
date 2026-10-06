# Prerequisites outside mise.toml: Xcode, and llvm and cppcheck under
# /opt/homebrew. Apple's clang ships no libFuzzer or LeakSanitizer.
set shell := ["bash", "-euo", "pipefail", "-c"]

export PATH := "/opt/homebrew/opt/llvm/bin:" + env("PATH")

c_sources := "CTask4PDF/*.c CTask4PDF/*/*.[ch] AppTests/Support/*.c App/*.h"

check: fmt-check lint typecheck test xctest fuzz coverage actions secrets reuse

ci-check: install check

install:
    mise install
    uv sync --frozen --project tests
    lefthook install

fmt:
    clang-format -i {{ c_sources }}
    swift format format --in-place --recursive App AppTests
    ruff format tests

fmt-check:
    clang-format --dry-run --Werror {{ c_sources }}
    swift format lint --strict --recursive App AppTests
    ruff format --check tests

lint: build
    swiftlint lint --strict
    ruff check tests

build:
    cmake --preset dev
    cmake --build --preset dev

typecheck:
    cd tests && uv run --frozen mypy .

test: build
    ctest --preset pytest

app: build
    xcodegen generate
    xcodebuild build -project Nullmark.xcodeproj -scheme Nullmark -configuration Release -derivedDataPath build/app

xctest: build
    xcodegen generate
    xcodebuild test -project Nullmark.xcodeproj -scheme Nullmark CODE_SIGNING_ALLOWED=NO

fuzz: build
    ctest --preset fuzz

coverage:
    cmake --workflow --preset coverage
    gcovr build/coverage

actions:
    actionlint
    zizmor --offline --pedantic .

secrets:
    gitleaks git

reuse:
    reuse lint
