#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]

REQUIRED = [
    "README.md",
    "README_EN.md",
    "LICENSE",
    "SECURITY.md",
    "PRIVACY.md",
    "CONTRIBUTING.md",
    "SUPPORT.md",
    "BUILDING.md",
    "COMPATIBILITY.md",
    "FAQ.md",
    "THIRD_PARTY_NOTICES.md",
    "OPEN_SOURCE_AND_DISCLAIMER.md",
    "CHANGELOG-Android.md",
    "CHANGELOG-Windows.md",
    "source/android/lib/app.dart",
    "source/windows/Runtime/DesktopSearch.cs",
]

FORBIDDEN_SUFFIXES = {
    ".apk",
    ".aab",
    ".exe",
    ".msi",
    ".dll",
    ".so",
    ".pdb",
    ".jks",
    ".keystore",
    ".pfx",
    ".p12",
    ".key",
}

SECRET_PATTERNS = {
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "fine-grained GitHub token": re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}\b"),
    "Google API key": re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    "JWT bearer token": re.compile(r"\bBearer\s+eyJ[A-Za-z0-9._-]{40,}"),
}

LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def text_files() -> list[Path]:
    result: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue
        if path.suffix.lower() in {
            ".md", ".txt", ".yml", ".yaml", ".json", ".py", ".dart",
            ".cs", ".c", ".h", ".cpp", ".kts", ".ps1", ".iss",
        }:
            result.append(path)
    return result


def check_links(errors: list[str]) -> None:
    for md in ROOT.rglob("*.md"):
        if ".git" in md.parts:
            continue
        content = md.read_text("utf-8", errors="replace")
        for raw in LINK.findall(content):
            target = raw.split("#", 1)[0].strip().strip("<>")
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            candidate = (md.parent / unquote(target)).resolve()
            try:
                candidate.relative_to(ROOT.resolve())
            except ValueError:
                fail(f"{md.relative_to(ROOT)}: link escapes repository: {raw}", errors)
                continue
            if not candidate.exists():
                fail(f"{md.relative_to(ROOT)}: missing local link target: {raw}", errors)


def main() -> int:
    errors: list[str] = []

    for name in REQUIRED:
        if not (ROOT / name).exists():
            fail(f"missing required file: {name}", errors)

    readme = (ROOT / "README.md").read_text("utf-8")
    for expected in ("Android 1.9.6", "Windows 0.5.8", "COMPATIBILITY.md", "SECURITY.md"):
        if expected not in readme:
            fail(f"README missing current reference: {expected}", errors)
    if "界面预览" in readme:
        fail("README must not restore the removed interface-preview section", errors)

    for path in ROOT.rglob("*"):
        if path.is_file() and ".git" not in path.parts and path.suffix.lower() in FORBIDDEN_SUFFIXES:
            fail(f"release binary or secret-like file committed: {path.relative_to(ROOT)}", errors)

    for path in text_files():
        content = path.read_text("utf-8", errors="replace")
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                fail(f"{label} pattern in {path.relative_to(ROOT)}", errors)

    for issue_form in (
        ROOT / ".github/ISSUE_TEMPLATE/android_bug.yml",
        ROOT / ".github/ISSUE_TEMPLATE/windows_bug.yml",
        ROOT / ".github/ISSUE_TEMPLATE/feature_request.yml",
    ):
        content = issue_form.read_text("utf-8") if issue_form.exists() else ""
        if "name:" not in content or "description:" not in content or "body:" not in content:
            fail(f"invalid issue form: {issue_form.relative_to(ROOT)}", errors)

    check_links(errors)

    if errors:
        print("Repository checks failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("Repository checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
