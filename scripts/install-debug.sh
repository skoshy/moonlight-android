#!/usr/bin/env bash
# Generic Android Debug APK Installation Script
# Automatically discovers adb, detects device ABI, selects the matching APK (handling flavor & ABI splits),
# deduplicates mDNS/stale connections, and installs onto the device personal profile (user 0) or specified user.

set -euo pipefail

show_help() {
    cat << 'EOF'
Usage: install-debug.sh [OPTIONS] [APK_PATH]

Arguments:
  APK_PATH                 Path to the debug APK file.
                           (Defaults to auto-discovering matching ABI/flavor debug APK)

Options:
  -s, --serial <SERIAL>    Target specific Android device serial (overrides auto-detection)
  -u, --user <USER_ID>     Install for specific Android user (default: 0)
      --all-users          Install for all users (omits --user flag)
      --flavor <FLAVOR>    Target specific flavor (e.g., nonRoot_game, root)
  -h, --help               Display this help message and exit

Environment Variables:
  ANDROID_SERIAL           Target device serial
  APK_PATH                 Path to the debug APK file
  ANDROID_HOME             Path to Android SDK
  ANDROID_SDK_ROOT         Path to Android SDK
EOF
}

TARGET_SERIAL="${ANDROID_SERIAL:-}"
TARGET_USER="0"
TARGET_FLAVOR=""
APK_INPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--serial)
            TARGET_SERIAL="$2"
            shift 2
            ;;
        -u|--user)
            TARGET_USER="$2"
            shift 2
            ;;
        --flavor)
            TARGET_FLAVOR="$2"
            shift 2
            ;;
        --all-users)
            TARGET_USER=""
            shift
            ;;
        *)
            if [ -z "$APK_INPUT" ]; then
                APK_INPUT="$1"
            else
                echo "Error: Unexpected argument: $1" >&2
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# 1. Locate adb binary across common locations
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

# 2. Handle device selection
if [ -n "$TARGET_SERIAL" ]; then
    TARGET_DEVICE="$TARGET_SERIAL"
    echo "Using specified device: $TARGET_DEVICE"
else
    fetch_devices

    # Check for duplicate mDNS entries like "name (2)._adb-tls-connect._tcp"
    if [ ${#devices[@]} -gt 1 ]; then
        has_mdns_dup=false
        for dev in "${devices[@]}"; do
            if [[ "$dev" =~ \([0-9]+\)\._adb ]]; then
                echo "Detected phantom duplicate mDNS connection: $dev"
                echo "Disconnecting stale connection..."
                "$ADB" disconnect "$dev" >/dev/null 2>&1 || true
                has_mdns_dup=true
            fi
        done
        if [ "$has_mdns_dup" = true ]; then
            fetch_devices
        fi
    fi

    # Check if multiple connected devices share the exact same hardware serial number
    if [ ${#devices[@]} -gt 1 ]; then
        first_serial=""
        all_same_hardware=true
        for dev in "${devices[@]}"; do
            serial=$("$ADB" -s "$dev" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n' || true)
            if [ -n "$serial" ]; then
                if [ -z "$first_serial" ]; then
                    first_serial="$serial"
                elif [ "$serial" != "$first_serial" ]; then
                    all_same_hardware=false
                    break
                fi
            fi
        done

        if [ "$all_same_hardware" = true ] && [ -n "$first_serial" ]; then
            echo "Multiple connections detected for the same physical device ($first_serial)."
            TARGET_DEVICE="${devices[0]}"
            echo "Using active connection: $TARGET_DEVICE"
            for (( i=1; i<${#devices[@]}; i++ )); do
                if [[ "${devices[$i]}" =~ _adb.*_tcp ]]; then
                    echo "Disconnecting duplicate connection: ${devices[$i]}"
                    "$ADB" disconnect "${devices[$i]}" >/dev/null 2>&1 || true
                fi
            done
            devices=("$TARGET_DEVICE")
        fi
    fi

    if [ ${#devices[@]} -eq 0 ]; then
        echo "Error: No Android devices or emulators attached." >&2
        echo "Check 'adb devices' or ensure USB/Wireless debugging is connected." >&2
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
                echo "Invalid choice. Defaulting to 1."
                TARGET_DEVICE="${devices[0]}"
            fi
        else
            echo "Non-interactive environment: defaulting to ${devices[0]}"
            TARGET_DEVICE="${devices[0]}"
        fi
    fi
fi

# 3. Locate matching APK for this device
find_best_apk() {
    if [ -n "$APK_INPUT" ]; then
        echo "$APK_INPUT"
        return
    fi
    if [ -n "${APK_PATH:-}" ]; then
        echo "$APK_PATH"
        return
    fi

    # Retrieve device ABI support
    local dev_abi dev_abilist
    dev_abi=$("$ADB" -s "$TARGET_DEVICE" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n' || true)
    dev_abilist=$("$ADB" -s "$TARGET_DEVICE" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r\n' || true)

    # Collect all candidate debug APKs
    local raw_candidates=()
    while IFS= read -r f; do
        if [ -n "$f" ]; then
            raw_candidates+=("$f")
        fi
    done < <(find . -maxdepth 6 -type f -path "*/build/outputs/apk/*debug*/*.apk" ! -name "*androidTest*" ! -name "*unaligned*" 2>/dev/null || true)

    if [ ${#raw_candidates[@]} -eq 0 ]; then
        # Fallback to single standard location
        if [ -f "app/build/outputs/apk/debug/app-debug.apk" ]; then
            echo "app/build/outputs/apk/debug/app-debug.apk"
            return
        fi
        echo ""
        return
    fi

    if [ ${#raw_candidates[@]} -eq 1 ]; then
        echo "${raw_candidates[0]}"
        return
    fi

    # Filter by flavor if requested (or prefer nonRoot if both root and nonRoot exist)
    local filtered=()
    if [ -n "$TARGET_FLAVOR" ]; then
        for c in "${raw_candidates[@]}"; do
            if [[ "$c" =~ $TARGET_FLAVOR ]]; then
                filtered+=("$c")
            fi
        done
    else
        # If both nonRoot and root variants exist, default to nonRoot
        local has_nonroot=false
        for c in "${raw_candidates[@]}"; do
            if [[ "$c" =~ nonRoot ]]; then
                has_nonroot=true
                break
            fi
        done
        if [ "$has_nonroot" = true ]; then
            for c in "${raw_candidates[@]}"; do
                if [[ "$c" =~ nonRoot ]]; then
                    filtered+=("$c")
                fi
            done
        else
            filtered=("${raw_candidates[@]}")
        fi
    fi

    # Match device ABI
    if [ -n "$dev_abi" ]; then
        for c in "${filtered[@]}"; do
            if [[ "$c" =~ $dev_abi ]]; then
                echo "$c"
                return
            fi
        done
    fi

    if [ -n "$dev_abilist" ]; then
        IFS=',' read -r -a abilist <<< "$dev_abilist"
        for abi in "${abilist[@]}"; do
            for c in "${filtered[@]}"; do
                if [[ "$c" =~ $abi ]]; then
                    echo "$c"
                    return
                fi
            done
        done
    fi

    # If universal APK exists
    for c in "${filtered[@]}"; do
        if [[ "$c" =~ universal ]]; then
            echo "$c"
            return
        fi
    done

    # Fallback to the first filtered APK
    echo "${filtered[0]}"
}

RESOLVED_APK="$(find_best_apk)"

if [ -z "$RESOLVED_APK" ] || [ ! -f "$RESOLVED_APK" ]; then
    echo "Error: Debug APK not found." >&2
    if [ -n "$RESOLVED_APK" ]; then
        echo "Specified path does not exist: $RESOLVED_APK" >&2
    fi
    echo "Build the debug APK first (e.g., './gradlew assembleNonRoot_gameDebug') or specify the path." >&2
    exit 1
fi

# 4. Install APK
INSTALL_ARGS=("-r")
if [ -n "$TARGET_USER" ]; then
    INSTALL_ARGS+=("--user" "$TARGET_USER")
    echo "Installing $(basename "$RESOLVED_APK") onto profile user $TARGET_USER of device: $TARGET_DEVICE..."
else
    echo "Installing $(basename "$RESOLVED_APK") onto device: $TARGET_DEVICE..."
fi

"$ADB" -s "$TARGET_DEVICE" install "${INSTALL_ARGS[@]}" "$RESOLVED_APK"
echo "✅ Successfully installed $RESOLVED_APK"
