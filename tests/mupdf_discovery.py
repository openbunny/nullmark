from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Final

_FALLBACK_PREFIXES: Final[tuple[Path, ...]] = (
    Path("/opt/homebrew"),
    Path("/usr/local"),
)


def _has_headers(prefix: Path) -> bool:
    return (prefix / "include" / "mupdf" / "fitz.h").exists()


def _from_pkg_config() -> tuple[Path, Path] | None:
    pkg_config = shutil.which("pkg-config")
    if not pkg_config:
        return None
    try:
        inc = subprocess.run(
            [pkg_config, "--variable=includedir", "mupdf"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        lib = subprocess.run(
            [pkg_config, "--variable=libdir", "mupdf"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if not inc or not lib:
        return None
    include, libdir = Path(inc), Path(lib)
    if not (include / "mupdf" / "fitz.h").exists():
        return None
    return include, libdir


def _from_brew_prefix() -> tuple[Path, Path] | None:
    brew = shutil.which("brew")
    if not brew:
        return None
    try:
        prefix = subprocess.run(
            [brew, "--prefix", "mupdf"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if not prefix:
        return None
    root = Path(prefix)
    if not _has_headers(root):
        return None
    return root / "include", root / "lib"


def discover_mupdf() -> tuple[Path, Path] | None:
    for finder in (_from_pkg_config, _from_brew_prefix):
        found = finder()
        if found is not None:
            return found
    for prefix in _FALLBACK_PREFIXES:
        if _has_headers(prefix):
            return prefix / "include", prefix / "lib"
    return None
