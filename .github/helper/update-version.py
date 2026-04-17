#!/usr/bin/env python3
"""
Bump Flutter package versions for semantic-release.

Updates:
- `pubspec.yaml` version -> <nextRelease.version>
- `example/pubspec.yaml` version -> <nextRelease.version>-dev
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]


def update_file_version(path: pathlib.Path, new_version: str) -> bool:
    content = path.read_text(encoding="utf-8")

    # Matches: version: 1.2.3 or version: 1.2.3-dev
    # Captures the key + whitespace so we preserve formatting.
    pattern = re.compile(r"^(version:\s*)([^\r\n#]+)$", re.MULTILINE)
    if not pattern.search(content):
        raise RuntimeError(f"Could not find `version:` in {path}")

    updated = pattern.sub(rf"\g<1>{new_version}", content)
    if updated != content:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python .github/helper/update-version.py <new_version>")
        sys.exit(1)

    new_version = sys.argv[1].strip()
    if not new_version:
        raise RuntimeError("New version is empty")

    pubspec = ROOT / "pubspec.yaml"
    example_pubspec = ROOT / "example" / "pubspec.yaml"

    changed_any = False

    changed_any |= update_file_version(pubspec, new_version)

    # Keep the existing convention of the example being <version>-dev.
    example_version = f"{new_version}-dev"
    changed_any |= update_file_version(example_pubspec, example_version)

    if changed_any:
        print(f"Bumped versions to {new_version}")
    else:
        print("Versions already up to date")


if __name__ == "__main__":
    main()
