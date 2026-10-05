from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

sys.path.insert(0, str(Path(__file__).parent))
import mupdf_discovery as md

if TYPE_CHECKING:
    import pytest


def _make_mupdf_tree(root: Path) -> None:
    (root / "include" / "mupdf").mkdir(parents=True)
    (root / "include" / "mupdf" / "fitz.h").write_text("")
    (root / "lib").mkdir(parents=True)


def test_discovers_via_pkg_config(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "pkgconfig-mupdf"
    _make_mupdf_tree(root)

    def fake_which(name: str) -> str | None:
        return "/usr/bin/pkg-config" if name == "pkg-config" else None

    def fake_run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        out = str(root / "include") if "includedir" in cmd[1] else str(root / "lib")
        return subprocess.CompletedProcess(cmd, 0, stdout=out + "\n", stderr="")

    monkeypatch.setattr("mupdf_discovery.shutil.which", fake_which)
    monkeypatch.setattr("mupdf_discovery.subprocess.run", fake_run)
    assert md.discover_mupdf() == (root / "include", root / "lib")


def test_discovers_via_brew_prefix_when_no_pkg_config(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "brew-mupdf"
    _make_mupdf_tree(root)

    def fake_which(name: str) -> str | None:
        return "/usr/bin/brew" if name == "brew" else None

    def fake_run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, 0, stdout=str(root) + "\n", stderr="")

    monkeypatch.setattr("mupdf_discovery.shutil.which", fake_which)
    monkeypatch.setattr("mupdf_discovery.subprocess.run", fake_run)
    assert md.discover_mupdf() == (root / "include", root / "lib")


def test_discovers_intel_homebrew_fallback_when_apple_silicon_prefix_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    intel = tmp_path / "usr-local"
    _make_mupdf_tree(intel)
    absent_apple_silicon = tmp_path / "opt-homebrew"

    monkeypatch.setattr("mupdf_discovery.shutil.which", lambda _name: None)
    monkeypatch.setattr(md, "_FALLBACK_PREFIXES", (absent_apple_silicon, intel))
    assert md.discover_mupdf() == (intel / "include", intel / "lib")


def test_returns_none_when_mupdf_is_nowhere(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("mupdf_discovery.shutil.which", lambda _name: None)
    monkeypatch.setattr(md, "_FALLBACK_PREFIXES", (tmp_path / "a", tmp_path / "b"))
    assert md.discover_mupdf() is None


def test_pkg_config_path_without_real_headers_is_not_trusted(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    stale = tmp_path / "stale"
    stale.mkdir()

    def fake_which(name: str) -> str | None:
        return "/usr/bin/pkg-config" if name == "pkg-config" else None

    def fake_run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(cmd, 0, stdout=str(stale) + "\n", stderr="")

    monkeypatch.setattr("mupdf_discovery.shutil.which", fake_which)
    monkeypatch.setattr("mupdf_discovery.subprocess.run", fake_run)
    monkeypatch.setattr(md, "_FALLBACK_PREFIXES", ())
    assert md.discover_mupdf() is None
