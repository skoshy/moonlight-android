#!/usr/bin/env python3
"""
Generic GitHub Release and APK Asset Upload Script for Android projects.
Supports single or multi-APK (flavor/ABI splits) projects.
Features:
  - Auto-detects project/app name, repository, and version
  - Verifies git state (uncommitted changes, sync with upstream remote)
  - Builds release APKs via Gradle
  - Discovers all generated release APKs (handles ABI splits & flavors)
  - Creates/updates annotated git tag
  - Publishes GitHub release with auto-generated release notes and attached APK asset(s)
"""
import sys
import os
import subprocess
import shutil
import re
import json
import argparse
from pathlib import Path

def get_app_name(project_root: Path, explicit_name: str = None) -> str:
    if explicit_name:
        return explicit_name
    for env_var in ("APP_NAME", "PROJECT_NAME"):
        val = os.environ.get(env_var)
        if val:
            return val.strip()

    # Try gh repo view
    try:
        res = subprocess.run(
            ["gh", "repo", "view", "--json", "name", "-q", ".name"],
            cwd=str(project_root),
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass

    # Try git remote url
    try:
        res = subprocess.run(
            ["git", "config", "--get", "remote.origin.url"],
            cwd=str(project_root),
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout.strip():
            url = res.stdout.strip()
            repo = url.rstrip("/").split("/")[-1]
            if repo.endswith(".git"):
                repo = repo[:-4]
            if repo:
                return repo
    except Exception:
        pass

    return project_root.name

def find_version_file(project_root: Path, explicit_file: str = None) -> Path:
    if explicit_file:
        p = Path(explicit_file)
        if not p.is_absolute():
            p = project_root / p
        if p.is_file():
            return p
        print(f"❌ Error: Specified version file not found: {p}", file=sys.stderr)
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

    for p in project_root.glob("*/version.properties"):
        if p.is_file():
            return p

    return None

def parse_version_info(target_file: Path):
    content = target_file.read_text(encoding="utf-8")
    name_match = re.search(r'(?m)^[ \t]*(?:baseVersionName|versionName|appVersionName|VERSION_NAME)[ \t]*[:=]?[ \t]*["\']?([^"\'\s\r\n]+)["\']?', content)
    code_match = re.search(r'(?m)^[ \t]*(?:appVersionCode|versionCode|VERSION_CODE)[ \t]*[:=]?[ \t]*(\d+)', content)

    if not name_match or not code_match:
        return None, None
    return name_match.group(1), int(code_match.group(1))

def find_release_apks(project_root: Path, explicit_apk: str = None, flavor: str = None) -> list:
    if explicit_apk:
        p = Path(explicit_apk)
        if not p.is_absolute():
            p = project_root / p
        if p.is_file():
            return [p]
        print(f"❌ Error: Specified APK not found: {p}", file=sys.stderr)
        sys.exit(1)

    # Search for built release APKs across standard and flavored output paths
    candidates = []
    # 1. Recursive glob in build/outputs/apk
    for p in project_root.glob("**/build/outputs/apk/**/*.apk"):
        # Must be in a release folder or named release
        if "release" not in p.parts and "release" not in p.name.lower():
            continue
        if "-v" in p.name or "androidTest" in p.name or "unaligned" in p.name:
            continue
        if flavor and flavor.lower() not in str(p).lower():
            continue
        candidates.append(p)

    # De-duplicate by canonical path
    unique = []
    seen = set()
    for p in candidates:
        if p.resolve() not in seen:
            seen.add(p.resolve())
            unique.append(p)

    # Prefer newer files
    unique.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return unique

def detect_tag_name(project_root: Path, version_name: str, explicit_tag: str = None, prefix: str = None) -> str:
    if explicit_tag:
        return explicit_tag
    if prefix is not None:
        return f"{prefix}{version_name}"

    # Auto-detect existing tag style from git repo
    try:
        res = subprocess.run(["git", "tag", "-l"], cwd=str(project_root), capture_output=True, text=True)
        tags = [t.strip() for t in res.stdout.splitlines() if t.strip()]
        if tags:
            v_count = sum(1 for t in tags if t.startswith("v"))
            no_v_count = sum(1 for t in tags if re.match(r'^\d+\.', t))
            if no_v_count > v_count:
                return version_name
    except Exception:
        pass

    return f"v{version_name}"

def get_latest_release(project_root: Path):
    """Query GitHub CLI for the latest repository release."""
    try:
        res = subprocess.run(
            ["gh", "release", "list", "--json", "tagName,name,publishedAt,isLatest,isDraft,isPrerelease", "--limit", "5"],
            cwd=str(project_root),
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout.strip():
            releases = json.loads(res.stdout)
            if releases:
                latest = next((r for r in releases if r.get("isLatest")), releases[0])
                tag = latest.get("tagName", "")
                name = latest.get("name", "")
                pub_date = (latest.get("publishedAt") or "")[:10]

                label = tag
                if name and name != tag:
                    label += f" - {name}"
                if pub_date:
                    label += f" ({pub_date})"
                return label, tag
    except Exception:
        pass
    return None, None

def main():
    parser = argparse.ArgumentParser(
        description="Generic GitHub Release and APK Asset Upload Script.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  ./scripts/release-github.sh\n"
               "  ./scripts/release-github.sh --yes\n"
               "  ./scripts/release-github.sh --draft\n"
               "  ./scripts/release-github.sh --flavor nonRoot_game\n"
               "  ./scripts/release-github.sh --task assembleNonRoot_gameRelease\n"
    )
    parser.add_argument("-n", "--name", dest="app_name", default=None, help="Application or release name (defaults to repository/project name)")
    parser.add_argument("-f", "--file", dest="version_file", default=None, help="Path to version file (defaults to version.properties or build.gradle[.kts])")
    parser.add_argument("-t", "--task", dest="gradle_task", default="assembleRelease", help="Gradle task to assemble APKs (default: assembleRelease)")
    parser.add_argument("--flavor", dest="flavor", default=None, help="Filter APKs by product flavor (e.g., nonRoot_game)")
    parser.add_argument("--apk", dest="apk_path", default=None, help="Explicit path to built APK file to upload")
    parser.add_argument("--tag", dest="explicit_tag", default=None, help="Explicit git release tag (e.g., v20.2.7 or 20.2.7)")
    parser.add_argument("--tag-prefix", dest="tag_prefix", default=None, help="Prefix for version tag (e.g. 'v' or '')")
    parser.add_argument("--title", dest="release_title", default=None, help="Custom release title (defaults to v<version> or <version>)")
    parser.add_argument("--notes", dest="custom_notes", default=None, help="Custom release notes to include above auto-generated changelog")
    parser.add_argument("-y", "--yes", action="store_true", help="Skip confirmation prompt")
    parser.add_argument("--draft", action="store_true", help="Save release as draft on GitHub")
    parser.add_argument("--prerelease", action="store_true", help="Mark release as pre-release on GitHub")

    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent

    # 1. Check gh CLI
    if not shutil.which("gh"):
        print("❌ Error: GitHub CLI ('gh') is not installed or not in PATH.", file=sys.stderr)
        print("   Install it via Homebrew (brew install gh) or package manager.", file=sys.stderr)
        sys.exit(1)

    # 2. Check gh auth
    auth_check = subprocess.run(["gh", "auth", "status"], cwd=str(project_root), capture_output=True, text=True)
    if auth_check.returncode != 0:
        print("❌ Error: You are not authenticated with GitHub CLI ('gh').", file=sys.stderr)
        print("   Please run: gh auth login", file=sys.stderr)
        sys.exit(1)

    # 3. Resolve app name and version
    app_name = get_app_name(project_root, args.app_name)
    version_file = find_version_file(project_root, args.version_file)
    if not version_file:
        print(f"❌ Error: Could not locate version.properties or build.gradle[.kts] in {project_root}", file=sys.stderr)
        sys.exit(1)

    version_name, version_code = parse_version_info(version_file)
    if not version_name or version_code is None:
        print(f"❌ Error: Could not parse versionCode or versionName from {version_file}", file=sys.stderr)
        sys.exit(1)

    tag = detect_tag_name(project_root, version_name, args.explicit_tag, args.tag_prefix)

    # 4. Fetch latest GitHub release
    latest_release_label, latest_tag = get_latest_release(project_root)

    print("=========================================")
    print(f"🚀 {app_name} GitHub Release & APK Upload")
    print("=========================================")
    if latest_release_label:
        print(f"Latest Release : {latest_release_label}")
    else:
        print("Latest Release : None (first release)")
    print(f"Target Version : {version_name} (versionCode: {version_code})")
    print(f"New Release Tag: {tag}")
    print(f"Version Source : {version_file.relative_to(project_root)}")
    print(f"Gradle Task    : {args.gradle_task}")
    if args.flavor:
        print(f"Target Flavor  : {args.flavor}")
    print("=========================================")

    if latest_tag == tag:
        print(f"⚠️  Warning: Tag '{tag}' matches the latest release tag on GitHub!")
        print("   Consider running './scripts/bump-version.sh' first if you haven't bumped yet.\n")

    # Confirmation
    if not args.yes:
        try:
            confirm = input(f"Proceed to build APK(s) and create release '{tag}'? [Y/n]: ").strip().lower()
            if confirm and confirm not in ("y", "yes"):
                print("Aborted.")
                sys.exit(0)
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            sys.exit(130)

    # 5. Git Status and Synchronization Validation
    status_proc = subprocess.run(["git", "status", "--porcelain"], cwd=str(project_root), capture_output=True, text=True)
    if status_proc.stdout.strip():
        print("❌ Error: Working tree has uncommitted changes. Please commit or stash them first:", file=sys.stderr)
        for line in status_proc.stdout.strip().splitlines():
            print(f"   {line}", file=sys.stderr)
        sys.exit(1)

    branch_proc = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=str(project_root), capture_output=True, text=True)
    current_branch = branch_proc.stdout.strip()

    upstream_proc = subprocess.run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd=str(project_root), capture_output=True, text=True)
    if upstream_proc.returncode == 0:
        upstream = upstream_proc.stdout.strip()
        ahead_proc = subprocess.run(["git", "rev-list", f"{upstream}..HEAD", "--count"], cwd=str(project_root), capture_output=True, text=True)
        ahead_count = int(ahead_proc.stdout.strip() or 0)
        if ahead_count > 0:
            print(f"⚠️  Notice: You have {ahead_count} unpushed commit(s) on branch '{current_branch}'.")
            if not args.yes:
                try:
                    push_confirm = input(f"Push {current_branch} to {upstream} now? [Y/n]: ").strip().lower()
                except (KeyboardInterrupt, EOFError):
                    print("\nAborted.")
                    sys.exit(130)
                if push_confirm and push_confirm not in ("y", "yes"):
                    print("❌ Aborted: Commits must be pushed to GitHub before releasing.", file=sys.stderr)
                    sys.exit(1)
            print(f"🚀 Pushing {current_branch} to {upstream}...")
            push_res = subprocess.run(["git", "push"], cwd=str(project_root))
            if push_res.returncode != 0:
                print("❌ Failed to push commits.", file=sys.stderr)
                sys.exit(push_res.returncode)
    else:
        print(f"⚠️  Warning: Current branch '{current_branch}' has no upstream remote configured.", file=sys.stderr)

    # 6. Build Release APK(s)
    print(f"\n📦 Building release APK(s) with Gradle ({args.gradle_task})...")
    gradlew = project_root / "gradlew"
    if not gradlew.exists():
        print(f"❌ Error: Gradle wrapper not found at {gradlew}", file=sys.stderr)
        sys.exit(1)

    # Execute via mise if available, else directly
    build_cmd = [str(gradlew), args.gradle_task]
    if shutil.which("mise"):
        build_cmd = ["mise", "exec", "--"] + build_cmd

    build_res = subprocess.run(build_cmd, cwd=str(project_root))
    if build_res.returncode != 0:
        print("❌ Gradle build failed.", file=sys.stderr)
        sys.exit(build_res.returncode)

    # Determine flavor filter from task if not explicitly given
    flavor = args.flavor
    if not flavor and "assemble" in args.gradle_task and "Release" in args.gradle_task:
        task_flavor = args.gradle_task.replace("assemble", "").replace("Release", "")
        if task_flavor:
            flavor = task_flavor

    release_apks = find_release_apks(project_root, args.apk_path, flavor)
    if not release_apks:
        print("❌ Error: Could not find generated release APK(s).", file=sys.stderr)
        sys.exit(1)

    # Prepare named release assets
    prepared_apks = []
    latest_built_version = version_name
    print(f"\n📦 Found {len(release_apks)} release APK asset(s):")
    for apk_source in release_apks:
        orig_name = apk_source.stem
        # Clean up -unsigned suffix for naming if present
        clean_name = re.sub(r'(-unsigned|-aligned)$', '', orig_name)

        if len(release_apks) == 1 and not any(abi in clean_name for abi in ["arm64", "armeabi", "x86"]):
            target_filename = f"{app_name}-v{version_name}.apk"
        else:
            # Preserve flavor/ABI descriptor from filename, but append version
            target_filename = f"{clean_name}-v{version_name}.apk"

        # Read built version name from output-metadata.json if available
        built_version = version_name
        metadata_file = apk_source.parent / "output-metadata.json"
        if metadata_file.exists():
            try:
                meta = json.loads(metadata_file.read_text(encoding="utf-8"))
                elements = meta.get("elements", [])
                for elem in elements:
                    if elem.get("outputFile") == apk_source.name and "versionName" in elem:
                        built_version = elem["versionName"]
                        latest_built_version = built_version
                        break
                else:
                    if elements and "versionName" in elements[0]:
                        built_version = elements[0]["versionName"]
                        latest_built_version = built_version
            except Exception:
                pass

        apk_dest = apk_source.parent / target_filename
        shutil.copyfile(apk_source, apk_dest)
        prepared_apks.append(apk_dest)
        print(f"   • {apk_dest.name} (version: {built_version}, {apk_dest.stat().st_size / (1024*1024):.2f} MB)")

    # 7. Create Git Tag and Push Tag
    head_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(project_root), capture_output=True, text=True).stdout.strip()
    tag_proc = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], cwd=str(project_root), capture_output=True, text=True)

    if tag_proc.returncode != 0:
        print(f"\n🏷️  Creating annotated git tag '{tag}' at commit {head_sha[:7]}...")
        tag_create = subprocess.run(["git", "tag", "-a", tag, "-m", f"Release {tag}"], cwd=str(project_root))
        if tag_create.returncode != 0:
            print("❌ Failed to create git tag.", file=sys.stderr)
            sys.exit(tag_create.returncode)
    else:
        tagged_commit = subprocess.run(["git", "rev-list", "-n", "1", tag], cwd=str(project_root), capture_output=True, text=True).stdout.strip()
        if tagged_commit != head_sha:
            print(f"\n🏷️  Updating existing git tag '{tag}' to HEAD ({head_sha[:7]})...")
            subprocess.run(["git", "tag", "-f", "-a", tag, "-m", f"Release {tag}"], cwd=str(project_root), check=True)

    print(f"⬆️  Pushing tag '{tag}' to origin...")
    push_tag = subprocess.run(["git", "push", "origin", tag], cwd=str(project_root))
    if push_tag.returncode != 0:
        print("❌ Failed to push tag to origin.", file=sys.stderr)
        sys.exit(push_tag.returncode)

    # 8. Create GitHub Release
    print(f"\n🌐 Creating GitHub release '{tag}' and uploading assets...")

    notes_parts = ["### 📦 Build Info"]
    notes_parts.append(f"- **Version:** `{version_name}`")
    if latest_built_version and latest_built_version != version_name:
        notes_parts.append(f"- **Build Number:** `{latest_built_version}`")
    notes_parts.append(f"- **Version Code:** `{version_code}`")
    notes_parts.append(f"- **Commit:** `{head_sha[:7]}`\n")

    if args.custom_notes:
        notes_parts.append(args.custom_notes.strip() + "\n")

    release_notes = "\n".join(notes_parts)
    default_title = args.release_title or (f"v{version_name}" if tag.startswith("v") else version_name)

    release_cmd = [
        "gh", "release", "create", tag,
        *[str(apk) for apk in prepared_apks],
        "--title", default_title,
        "--notes", release_notes,
        "--generate-notes",
        "--target", head_sha
    ]

    if args.draft:
        release_cmd.append("--draft")
    if args.prerelease:
        release_cmd.append("--prerelease")

    res = subprocess.run(release_cmd, cwd=str(project_root))
    if res.returncode == 0:
        print(f"\n🎉 Successfully published release {tag} on GitHub!")
    else:
        print(f"\n❌ Failed to create GitHub release (exit code {res.returncode}).", file=sys.stderr)
        sys.exit(res.returncode)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)
