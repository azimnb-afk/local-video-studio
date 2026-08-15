#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local Video Studio — Canonical Development Build & Launch Helper
#
# Builds the macOS Dev application into the canonical build location with
# isolated bundle ID (com.localvideostudio.dev) and prints/launches the .app.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/LTXVideoGenerator/LTXVideoGenerator.xcodeproj"
SCHEME="LTXVideoGenerator"
CONFIGURATION="Debug"

SHOULD_LAUNCH=false
SHOULD_CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --open|--launch|-o)
            SHOULD_LAUNCH=true
            ;;
        --clean|-c)
            SHOULD_CLEAN=true
            ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--open]"
            echo "  --clean, -c   Perform clean build before compiling"
            echo "  --open,  -o   Launch the canonical dev app after successful build"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

if [ ! -d "${PROJECT_PATH}" ]; then
    echo "Error: Xcode project not found at: ${PROJECT_PATH}" >&2
    exit 1
fi

echo "==> Building Local Video Studio Dev (${CONFIGURATION})..."
BUILD_ACTION="build"
if [ "${SHOULD_CLEAN}" = true ]; then
    BUILD_ACTION="clean build"
fi

# CFBundleDisplayName alone is not enough: on current macOS the menu bar
# application menu (top-left, bold) reads CFBundleName, not
# CFBundleDisplayName — verified empirically via System Events on this
# build ("displayed name" showed Local Video Studio Dev while the actual
# app menu title still showed LTXVideoGenerator). With
# GENERATE_INFOPLIST_FILE=YES, Xcode always derives CFBundleName from
# PRODUCT_NAME (INFOPLIST_KEY_CFBundleName has no effect on it), so
# PRODUCT_NAME is overridden too. This also renames CFBundleExecutable and
# the .app bundle filename for this Dev build — the Xcode project's own
# target/module name is untouched.
xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    PRODUCT_BUNDLE_IDENTIFIER="com.localvideostudio.dev" \
    PRODUCT_NAME="Local Video Studio Dev" \
    INFOPLIST_KEY_CFBundleDisplayName="Local Video Studio Dev" \
    CODE_SIGNING_ALLOWED=NO \
    ${BUILD_ACTION}

BUILD_SETTINGS=$(xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "platform=macOS" PRODUCT_NAME="Local Video Studio Dev" -showBuildSettings 2>/dev/null)
TARGET_BUILD_DIR=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR / {print $2; exit}')
FULL_PRODUCT_NAME=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME / {print $2; exit}')

CANONICAL_APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"

if [ ! -d "${CANONICAL_APP}" ]; then
    echo "Error: Build succeeded but .app bundle was not found at ${CANONICAL_APP}" >&2
    exit 1
fi

echo ""
echo "=============================================================================="
echo "CANONICAL DEVELOPMENT APP:"
echo "${CANONICAL_APP}"
echo "Bundle ID: com.localvideostudio.dev"
echo "Storage:   ~/Library/Application Support/LocalVideoStudioDev"
echo "=============================================================================="

if [ "${SHOULD_LAUNCH}" = true ]; then
    echo "==> Launching development app..."
    open "${CANONICAL_APP}"
fi
