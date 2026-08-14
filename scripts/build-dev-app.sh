#!/bin/bash
set -euo pipefail

# ==============================================================================
# LTX Video Generator — Canonical Development Build & Launch Helper
#
# Builds the macOS Debug application into the canonical DerivedData location
# and prints/launches the exact single canonical .app path.
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
            echo "  --open,  -o   Launch the canonical app after successful build"
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

echo "==> Resolving canonical build directory..."
BUILD_SETTINGS=$(xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "platform=macOS" -showBuildSettings 2>/dev/null)
TARGET_BUILD_DIR=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR / {print $2; exit}')
FULL_PRODUCT_NAME=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME / {print $2; exit}')

if [ -z "${TARGET_BUILD_DIR}" ] || [ -z "${FULL_PRODUCT_NAME}" ]; then
    echo "Error: Could not resolve build output settings from xcodebuild." >&2
    exit 1
fi

CANONICAL_APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"

echo "==> Building ${SCHEME} (${CONFIGURATION})..."
BUILD_ACTION="build"
if [ "${SHOULD_CLEAN}" = true ]; then
    BUILD_ACTION="clean build"
fi

xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    ${BUILD_ACTION}

if [ ! -d "${CANONICAL_APP}" ]; then
    echo "Error: Build succeeded but .app bundle was not found at ${CANONICAL_APP}" >&2
    exit 1
fi

echo ""
echo "=============================================================================="
echo "CANONICAL DEVELOPMENT APP:"
echo "${CANONICAL_APP}"
echo "=============================================================================="

if [ "${SHOULD_LAUNCH}" = true ]; then
    echo "==> Launching canonical app..."
    open "${CANONICAL_APP}"
fi
