#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.request


REQUIRED = {
    "android-v2.2.4": {
        "Yingyu-2.2.4.apk",
        "Yingyu-2.2.4-source.zip",
        "Yingyu-2.2.4-symbols.zip",
        "android-2.2.4.md",
        "android-2.2.4-SHA256SUMS.txt",
    },
    "windows-v1.2.2": {
        "Yingyu-Setup-x64-1.2.2.exe",
        "Yingyu-1.2.2-source-and-symbols.zip",
        "windows-1.2.2.md",
        "windows-1.2.2-SHA256SUMS.txt",
    },
}


def get_json(url: str) -> object:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    repository = os.environ["GITHUB_REPOSITORY"]
    failures: list[str] = []
    for tag, expected in REQUIRED.items():
        release = get_json(f"https://api.github.com/repos/{repository}/releases/tags/{tag}")
        if release.get("draft") or release.get("prerelease"):
            failures.append(f"{tag}: release must be published and stable")
        assets = {asset["name"]: asset for asset in release["assets"]}
        missing = expected - set(assets)
        if missing:
            failures.append(f"{tag}: missing {sorted(missing)}")
        for name in expected & set(assets):
            asset = assets[name]
            if asset.get("state") != "uploaded" or int(asset.get("size", 0)) <= 0:
                failures.append(f"{tag}: incomplete asset {name}")
            if not asset.get("digest", "").startswith("sha256:"):
                failures.append(f"{tag}: missing GitHub SHA-256 digest for {name}")
    if failures:
        print("\n".join(failures))
        return 1
    print("Release assets are complete and have GitHub SHA-256 digests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
