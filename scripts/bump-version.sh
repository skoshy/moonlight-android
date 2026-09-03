#!/usr/bin/env python3
"""
Generic Version Bumper for Android and Gradle/JVM projects.
Supports:
  - version.properties (baseVersionName / versionName, versionCode)
  - build.gradle.kts / build.gradle (Kotlin DSL or Groovy)
"""
import sys
import os
import re
import argparse
from pathlib import Path

def find_version_file(project_root: Path, explicit_path: str = None) -> Path:
    if explicit_path:
        p = Path(explicit_path)
        if not p.is_absolute():
            p = project_root / p
        if p.is_file():
            return p
        print(f"Error: Specified version file not found: {p}", file=sys.stderr)
        sys.exit(1)

    env_path = os.environ.get("VERSION_FILE")
    if env_path:
        p = Path(env_path)
        if not p.is_absolute():
            p = project_root / p
        if p.is_file():
            return p

    candidates = [
        project_root / "version.properties",
        project_root / "app" / "build.gradle.kts",
        project_root / "app" / "build.gradle",
        project_root / "build.gradle.kts",
        project_root / "build.gradle",
    ]
    for c in candidates:
        if c.is_file():
            return c

    # Search subdirectories for version.properties
    for p in project_root.glob("*/version.properties"):
        if p.is_file():
            return p

    return None

def parse_semver(version_str: str):
    """Parses major, minor, patch from version string, ignoring prerelease/build suffix for math."""
    # Match standard X.Y.Z
    match = re.match(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?', version_str.strip())
    if match:
        major = int(match.group(1) or 0)
        minor = int(match.group(2) or 0)
        patch = int(match.group(3) or 0)
        return major, minor, patch
    return 0, 0, 0

def main():
    parser = argparse.ArgumentParser(
        description="Generic version bumper for Android and Gradle projects.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  ./scripts/bump-version.sh patch\n"
               "  ./scripts/bump-version.sh minor\n"
               "  ./scripts/bump-version.sh major\n"
               "  ./scripts/bump-version.sh --file app/build.gradle patch\n"
    )
    parser.add_argument(
        "type",
        nargs="?",
        choices=["patch", "minor", "major", "1", "2", "3", "p", "m"],
        help="Version component to bump (or select interactively if omitted)"
    )
    parser.add_argument(
        "-f", "--file",
        dest="target_file",
        default=None,
        help="Path to version file (defaults to version.properties or build.gradle[.kts])"
    )

    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent

    target_file = find_version_file(project_root, args.target_file)
    if not target_file:
        print(f"Error: Could not locate version.properties or build.gradle[.kts] in {project_root}", file=sys.stderr)
        sys.exit(1)

    content = target_file.read_text(encoding="utf-8")

    code_match = re.search(r'(?m)^[ \t]*(?:appVersionCode|versionCode|VERSION_CODE)[ \t]*[:=]?[ \t]*(\d+)', content)
    name_match = re.search(r'(?m)^[ \t]*(?:baseVersionName|versionName|appVersionName|VERSION_NAME)[ \t]*[:=]?[ \t]*["\']?([^"\'\s\r\n]+)["\']?', content)

    if not code_match or not name_match:
        print(f"Error: Could not parse versionCode or baseVersionName/versionName from {target_file}", file=sys.stderr)
        sys.exit(1)

    version_code = int(code_match.group(1))
    version_name = name_match.group(1)

    major, minor, patch = parse_semver(version_name)

    next_patch = f"{major}.{minor}.{patch + 1}"
    next_minor = f"{major}.{minor + 1}.0"
    next_major = f"{major + 1}.0.0"
    next_code = version_code + 1

    bump_type = args.type.lower() if args.type else None

    if not bump_type:
        print("=========================================")
        print(f"Current Base Version: {version_name} (versionCode: {version_code})")
        print(f"Source File         : {target_file.relative_to(project_root)}")
        print("=========================================")
        print("Select which part of the version to increase:")
        print(f"  1) patch  -> {next_patch} (versionCode: {next_code})")
        print(f"  2) minor  -> {next_minor} (versionCode: {next_code})")
        print(f"  3) major  -> {next_major} (versionCode: {next_code})")
        print()
        try:
            bump_type = input("Enter choice [1-3, or patch/minor/major]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            sys.exit(1)

    if bump_type in ("1", "patch", "p"):
        new_version_name = next_patch
        bump_label = "patch"
    elif bump_type in ("2", "minor", "m"):
        new_version_name = next_minor
        bump_label = "minor"
    elif bump_type in ("3", "major"):
        new_version_name = next_major
        bump_label = "major"
    else:
        print(f"Error: Invalid choice '{bump_type}'. Must be patch, minor, or major (1, 2, or 3).", file=sys.stderr)
        sys.exit(1)

    # In-place regex replacement preserving formatting and other properties
    is_properties = target_file.suffix == ".properties" or "properties" in target_file.name

    if is_properties:
        # Update version name
        content = re.sub(
            r'(?m)^([ \t]*(?:baseVersionName|versionName|appVersionName|VERSION_NAME)[ \t]*[:=][ \t]*).*$',
            rf'\g<1>{new_version_name}',
            content,
            count=1
        )
        # Update version code
        content = re.sub(
            r'(?m)^([ \t]*(?:versionCode|appVersionCode|VERSION_CODE)[ \t]*[:=][ \t]*)\d+.*$',
            rf'\g<1>{next_code}',
            content,
            count=1
        )
    else:
        # Gradle (Kotlin DSL or Groovy)
        content = re.sub(
            r'(?m)^([ \t]*(?:appVersionCode|versionCode)[ \t]*=?\s*)\d+',
            rf'\g<1>{next_code}',
            content,
            count=1
        )
        content = re.sub(
            r'(?m)^([ \t]*(?:baseVersionName|versionName|appVersionName)[ \t]*=?\s*["\'])[^"\']+(["\'])',
            rf'\g<1>{new_version_name}\g<2>',
            content,
            count=1
        )

    target_file.write_text(content, encoding="utf-8")

    print()
    print(f"✅ Successfully updated version ({bump_label} bump):")
    print(f"   Version Name: {version_name} -> {new_version_name}")
    print(f"   versionCode : {version_code} -> {next_code}")
    print(f"   File updated: {target_file.relative_to(project_root)}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)
