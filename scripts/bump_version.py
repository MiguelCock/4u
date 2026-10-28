"""Bumps the app to a new version for a release PR, in every place that
names it:

- application/pubspec.yaml: `version: X.Y.Z+N`, N = X*10000 + Y*100 + Z, so
  Android's versionCode always increases and an update installs over the
  old app;
- CHANGELOG.md: `## [Unreleased]` becomes `## [X.Y.Z] - today` (with an
  empty Unreleased above it) and the compare links follow;
- packages/src/packages/app_versions.json: the new version becomes
  `latest`, and the previous `latest` becomes `min_supported` - it stays
  usable but deprecated, and anything older is refused (426).

    python3 scripts/bump_version.py 0.5.2
"""

import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "application" / "pubspec.yaml"
CHANGELOG = ROOT / "CHANGELOG.md"
POLICY = ROOT / "packages" / "src" / "packages" / "app_versions.json"
REPO = "https://github.com/MiguelCock/4u"


def parse(version: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        raise SystemExit(f"expected X.Y.Z, got {version!r}")
    return tuple(int(part) for part in match.groups())


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    new = sys.argv[1]
    major, minor, patch = parse(new)

    policy = json.loads(POLICY.read_text())
    old = policy["latest"]
    if parse(new) <= parse(old):
        raise SystemExit(f"{new} is not newer than the current {old}")

    pubspec = PUBSPEC.read_text()
    build = major * 10000 + minor * 100 + patch
    pubspec, n = re.subn(
        r"^version:.*$", f"version: {new}+{build}", pubspec, count=1, flags=re.M
    )
    if n != 1:
        raise SystemExit("no version: line in pubspec.yaml")

    changelog = CHANGELOG.read_text()
    if f"## [{new}]" in changelog:
        raise SystemExit(f"CHANGELOG.md already has a [{new}] section")
    today = datetime.date.today().isoformat()
    changelog = changelog.replace(
        "## [Unreleased]\n", f"## [Unreleased]\n\n## [{new}] - {today}\n", 1
    )
    changelog = re.sub(
        r"^\[Unreleased\]: .*$",
        f"[Unreleased]: {REPO}/compare/v{new}...develop\n"
        f"[{new}]: {REPO}/compare/v{old}...v{new}",
        changelog,
        count=1,
        flags=re.M,
    )

    policy["min_supported"] = old
    policy["latest"] = new

    PUBSPEC.write_text(pubspec)
    CHANGELOG.write_text(changelog)
    POLICY.write_text(json.dumps(policy, indent=2) + "\n")
    print(f"{old} -> {new} (build {build}); {old} is now deprecated, older refused")


if __name__ == "__main__":
    main()
