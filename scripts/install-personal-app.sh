#!/bin/bash
set -euo pipefail

# ==============================================================================
# Local Video Studio — Personal App Build & Install Helper
#
# Builds the macOS Release application into ~/Applications/Local Video Studio.app
# with isolated personal bundle ID (com.localvideostudio.personal) and registers it.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/LTXVideoGenerator/LTXVideoGenerator.xcodeproj"
SCHEME="LTXVideoGenerator"
CONFIGURATION="Release"
TARGET_DIR="${HOME}/Applications"
TARGET_APP="${TARGET_DIR}/Local Video Studio.app"

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
            echo "  --open,  -o   Launch the personal app after successful install"
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

mkdir -p "${TARGET_DIR}"

echo "==> Building Local Video Studio Personal (${CONFIGURATION})..."
BUILD_ACTION="build"
if [ "${SHOULD_CLEAN}" = true ]; then
    BUILD_ACTION="clean build"
fi

# CFBundleDisplayName alone is not enough: on current macOS the menu bar
# application menu (top-left, bold) reads CFBundleName, not
# CFBundleDisplayName — verified empirically via System Events (the "displayed
# name" showed the correct name while the actual app menu title still showed
# LTXVideoGenerator until CFBundleName was also fixed). With
# GENERATE_INFOPLIST_FILE=YES, Xcode always derives CFBundleName from
# PRODUCT_NAME (INFOPLIST_KEY_CFBundleName has no effect on it), so
# PRODUCT_NAME is overridden too. This also renames CFBundleExecutable — the
# Xcode project's own target/module name is untouched. The renamed .app is
# then copied to "Local Video Studio.app" below either way.
xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    PRODUCT_BUNDLE_IDENTIFIER="com.localvideostudio.personal" \
    PRODUCT_NAME="Local Video Studio" \
    INFOPLIST_KEY_CFBundleDisplayName="Local Video Studio" \
    CODE_SIGNING_ALLOWED=NO \
    ${BUILD_ACTION}

BUILD_SETTINGS=$(xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "platform=macOS" PRODUCT_NAME="Local Video Studio" -showBuildSettings 2>/dev/null)
TARGET_BUILD_DIR=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR / {print $2; exit}')
FULL_PRODUCT_NAME=$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME / {print $2; exit}')
BUILT_APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"

if [ ! -d "${BUILT_APP}" ]; then
    echo "Error: Build succeeded but .app bundle was not found at ${BUILT_APP}" >&2
    exit 1
fi

# Defensive path verification
if [ -z "${TARGET_APP:-}" ] || [ "${TARGET_APP}" = "/" ] || [ "${TARGET_APP}" = "${HOME}" ] || [ "${TARGET_APP}" != "${HOME}/Applications/Local Video Studio.app" ]; then
    echo "Error: Refusing to replace invalid or unsafe TARGET_APP path: '${TARGET_APP}'" >&2
    exit 1
fi

echo "==> Installing into ${TARGET_APP}..."
if [ -d "${TARGET_APP}" ]; then
    BACKUP_PATH="/private/tmp/LocalVideoStudio_backup_$(date +%s).app"
    mv "${TARGET_APP}" "${BACKUP_PATH}"
fi
cp -R "${BUILT_APP}" "${TARGET_APP}"

echo "==> Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${TARGET_APP}" || true

echo ""
echo "=============================================================================="
echo "PERSONAL APP INSTALLED SUCCESSFULLY:"
echo "${TARGET_APP}"
echo "Bundle ID: com.localvideostudio.personal"
echo "Storage:   ~/Library/Application Support/LocalVideoStudio"
echo "=============================================================================="

if [ "${SHOULD_LAUNCH}" = true ]; then
    echo "==> Launching Local Video Studio..."
    open "${TARGET_APP}"
fi
