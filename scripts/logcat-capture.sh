#!/usr/bin/env bash
# Generic Android Logcat Crash Capture Script
# Automatically discovers adb, package name (including flavor/debug suffix), and devices to stream/capture crash logs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
PROJECT_LOWER="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')"

show_help() {
    cat << EOF
Usage: logcat-capture.sh [OPTIONS] [PACKAGE_NAME] [LOG_FILE]

Arguments:
  PACKAGE_NAME             Android package/application ID (e.g. com.limelight.noirdebug)
                           Auto-detected from project or installed packages if omitted.
  LOG_FILE                 File to save output log to (default: ${PROJECT_LOWER}_crash_log.txt)

Options:
  -p, --package <PACKAGE>  Specify Android application package name
  -o, --output <FILE>      Specify output log file path
  -s, --serial <SERIAL>    Target specific Android device serial
      --no-clear           Do not clear the logcat buffer before capturing
  -h, --help               Display this help message and exit

Environment Variables:
  PACKAGE_NAME             Android application package ID
  LOG_FILE                 Log destination path
  ANDROID_SERIAL           Target device serial
  ANDROID_HOME             Path to Android SDK
  ANDROID_SDK_ROOT         Path to Android SDK
EOF
}

TARGET_SERIAL="${ANDROID_SERIAL:-}"
PACKAGE_INPUT=""
LOG_FILE_INPUT=""
CLEAR_LOGCAT=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--package)
            PACKAGE_INPUT="$2"
            shift 2
            ;;
        -o|--output)
            LOG_FILE_INPUT="$2"
            shift 2
            ;;
        -s|--serial)
            TARGET_SERIAL="$2"
            shift 2
            ;;
        --no-clear)
            CLEAR_LOGCAT=false
            shift
            ;;
        *)
            if [ -z "$PACKAGE_INPUT" ]; then
                PACKAGE_INPUT="$1"
            elif [ -z "$LOG_FILE_INPUT" ]; then
                LOG_FILE_INPUT="$1"
            else
                echo "Error: Unexpected argument: $1" >&2
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# 1. Locate adb binary
find_adb() {
    if command -v adb >/dev/null 2>&1; then
        command -v adb
    elif [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
        echo "$ANDROID_HOME/platform-tools/adb"
    elif [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
        echo "$ANDROID_SDK_ROOT/platform-tools/adb"
    elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
        echo "$HOME/Library/Android/sdk/platform-tools/adb"
    elif [ -x "$HOME/Android/Sdk/platform-tools/adb" ]; then
        echo "$HOME/Android/Sdk/platform-tools/adb"
    elif [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" ]; then
        echo "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
    elif [ -x "/opt/android-sdk/platform-tools/adb" ]; then
        echo "/opt/android-sdk/platform-tools/adb"
    else
        return 1
    fi
}

ADB="$(find_adb || true)"
if [ -z "$ADB" ]; then
    echo "Error: 'adb' command not found in PATH or standard Android SDK directories." >&2
    echo "Please set ANDROID_HOME or add platform-tools to PATH." >&2
    exit 1
fi

# 2. Device discovery & selection
get_devices() {
    "$ADB" devices | sed -n '1!s/[[:space:]]\{1,\}device$//p'
}

fetch_devices() {
    devices=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            devices+=("$line")
        fi
    done < <(get_devices)
}

if [ -n "$TARGET_SERIAL" ]; then
    TARGET_DEVICE="$TARGET_SERIAL"
else
    fetch_devices

    # Filter out duplicate mDNS if any
    if [ ${#devices[@]} -gt 1 ]; then
        for dev in "${devices[@]}"; do
            if [[ "$dev" =~ \([0-9]+\)\._adb ]]; then
                "$ADB" disconnect "$dev" >/dev/null 2>&1 || true
            fi
        done
        fetch_devices
    fi

    if [ ${#devices[@]} -eq 0 ]; then
        echo "Error: No Android devices or emulators attached." >&2
        echo "Check 'adb devices' or toggle USB/Wireless debugging." >&2
        exit 1
    elif [ ${#devices[@]} -eq 1 ]; then
        TARGET_DEVICE="${devices[0]}"
    else
        echo "Multiple devices detected:"
        for i in "${!devices[@]}"; do
            dev="${devices[$i]}"
            model=$("$ADB" -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n' || true)
            echo "  [$((i + 1))] $dev ${model:+($model)}"
        done

        if [ -t 0 ]; then
            read -r -p "Select device [1-${#devices[@]}] (default 1): " choice || choice="1"
            choice="${choice:-1}"
            idx=$((choice - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#devices[@]}" ]; then
                TARGET_DEVICE="${devices[$idx]}"
            else
                TARGET_DEVICE="${devices[0]}"
            fi
        else
            TARGET_DEVICE="${devices[0]}"
        fi
    fi
fi

# 3. Resolve package name
find_package_name() {
    if [ -n "$PACKAGE_INPUT" ]; then
        echo "$PACKAGE_INPUT"
        return
    fi
    if [ -n "${PACKAGE_NAME:-}" ]; then
        echo "$PACKAGE_NAME"
        return
    fi

    # Check installed packages on target device for limelight or moonlight
    if [ -n "${TARGET_DEVICE:-}" ]; then
        local installed
        # Check for debug suffix first
        installed=$("$ADB" -s "$TARGET_DEVICE" shell pm list packages 2>/dev/null | grep -E 'limelight.*debug|moonlight.*debug' | head -n 1 | sed 's/^package://' | tr -d '\r\n' || true)
        if [ -n "$installed" ]; then
            echo "$installed"
            return
        fi
        # Check any limelight or moonlight package
        installed=$("$ADB" -s "$TARGET_DEVICE" shell pm list packages 2>/dev/null | grep -E 'limelight|moonlight' | head -n 1 | sed 's/^package://' | tr -d '\r\n' || true)
        if [ -n "$installed" ]; then
            echo "$installed"
            return
        fi
    fi

    # Scan Gradle build files for applicationId + debug suffix
    local base_pkg="" suffix=""
    for file in "$PROJECT_ROOT/app/build.gradle.kts" "$PROJECT_ROOT/app/build.gradle" "$PROJECT_ROOT/build.gradle.kts" "$PROJECT_ROOT/build.gradle"; do
        if [ -f "$file" ]; then
            # Extract applicationId or namespace
            base_pkg=$(grep -E 'applicationId[[:space:]]*(=|[[:space:]])[[:space:]]*"[^"]+"' "$file" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
            if [ -z "$base_pkg" ]; then
                base_pkg=$(grep -E 'namespace[[:space:]]*(=|[[:space:]])[[:space:]]*"[^"]+"' "$file" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
            fi

            # Check if debug buildType has applicationIdSuffix
            suffix=$(sed -n '/debug[[:space:]]*{/,/}/p' "$file" | grep -E 'applicationIdSuffix[[:space:]]*(=|[[:space:]])[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

            if [ -n "$base_pkg" ]; then
                echo "${base_pkg}${suffix}"
                return
            fi
        fi
    done

    # Check AndroidManifest.xml
    local manifest
    manifest=$(find "$PROJECT_ROOT" -maxdepth 5 -name "AndroidManifest.xml" 2>/dev/null | head -n 1 || true)
    if [ -n "$manifest" ] && [ -f "$manifest" ]; then
        base_pkg=$(grep -E 'package="[^"]+"' "$manifest" | head -n 1 | sed -E 's/.*package="([^"]+)".*/\1/' || true)
        if [ -n "$base_pkg" ]; then
            echo "$base_pkg"
            return
        fi
    fi

    echo ""
}

RESOLVED_PACKAGE="$(find_package_name)"
if [ -z "$RESOLVED_PACKAGE" ]; then
    echo "Error: Could not auto-detect Android package name." >&2
    echo "Please provide it with: $0 -p <package_name>" >&2
    exit 1
fi

# 4. Resolve log file destination
RESOLVED_LOG_FILE="${LOG_FILE_INPUT:-${LOG_FILE:-${PROJECT_LOWER}_crash_log.txt}}"

ADB_TARGET=("$ADB" -s "$TARGET_DEVICE")

echo "========================================="
echo "📱 Android Crash Log Capture: $PROJECT_NAME"
echo "========================================="
echo "Target Device: $TARGET_DEVICE"
echo "Package Name : $RESOLVED_PACKAGE"
echo "Log File     : $RESOLVED_LOG_FILE"
echo "Trigger the crash now..."
echo "Press Ctrl+C to stop logging"
echo "========================================="

# Clear previous log buffer if requested
if [ "$CLEAR_LOGCAT" = true ]; then
    "${ADB_TARGET[@]}" logcat -c
fi

# Filter by package name, tags, and common crash indicators
"${ADB_TARGET[@]}" logcat -v time \
  "$RESOLVED_PACKAGE:I" \
  "AndroidRuntime:E" \
  "FATAL:E" \
  "Exception:E" \
  "Crash:E" \
  "AndroidRuntime:W" \
  "ActivityManager:W" \
  "ActivityManager:D" \
  "$RESOLVED_PACKAGE:V" \
  "*:S" \
  2>&1 | tee "$RESOLVED_LOG_FILE"
