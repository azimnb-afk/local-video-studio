#!/bin/bash
set -euo pipefail

# Local Video Studio - Release Build Script
# Supports two modes: local-test and distribution

# Configuration
# APP_DISPLAY_NAME is what users actually see: CFBundleName (which the macOS
# menu bar application menu reads — CFBundleDisplayName alone does not cover
# it, verified empirically), CFBundleExecutable, the shipped .app filename
# inside the DMG, the DMG filename, and the mounted volume name. It is passed
# as PRODUCT_NAME to the archive build below, so the archived product is
# already correctly named — the Xcode project's own target/module name is
# untouched.
APP_DISPLAY_NAME="Local Video Studio"
SCHEME="LTXVideoGenerator"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="${PROJECT_DIR}/dist"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_DISPLAY_NAME}.app"

# Mode configuration. Never infer distribution intent from ambient credentials:
# explicit mode keeps local-test and release artifacts impossible to confuse.
MODE="${1:-}"

usage() {
    cat <<'EOF'
Usage: ./scripts/build-release.sh <local-test|preview|distribution> [preview-tag]

local-test    Release archive, ad-hoc signed LOCAL TEST ONLY DMG. No notarization.
preview       Release archive, ad-hoc signed preview release candidate DMG.
distribution  Developer ID signed, notarized, stapled distribution DMG.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_distribution_credentials() {
    [ -n "${CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGN_IDENTITY}" != "-" ] || \
        fail "Developer ID Application signing identity is required for distribution. Set CODE_SIGN_IDENTITY."

    security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${CODE_SIGN_IDENTITY}" || \
        fail "CODE_SIGN_IDENTITY was not found among valid code-signing identities."
    [[ "${CODE_SIGN_IDENTITY}" == *"Developer ID Application"* ]] || \
        fail "CODE_SIGN_IDENTITY must name a Developer ID Application identity."
    [ -n "${MINIMAX_H3_RUNTIME_PAYLOAD_SOURCE:-}" ] || \
        fail "Set MINIMAX_H3_RUNTIME_PAYLOAD_SOURCE to the audited mlx-serve 26.8.9 payload for distribution."

    if [ -n "${NOTARY_PROFILE:-}" ]; then
        return
    fi

    [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_ID_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] || \
        fail "Notary credentials are required: set NOTARY_PROFILE or APPLE_ID, APPLE_ID_PASSWORD, and APPLE_TEAM_ID."
}

case "$MODE" in
local-test)
    echo "=== Local Video Studio Build ==="
    echo "Mode: local-test"
    echo "WARNING: This is a local test build. NOT FOR DISTRIBUTION."
    ;;
preview)
    echo "=== Local Video Studio Build ==="
    echo "Mode: preview"
    ;;
distribution)
    echo "=== Local Video Studio Build ==="
    echo "Mode: distribution"
    require_distribution_credentials
    ;;
*)
    usage >&2
    exit 64
    ;;
esac

# Get version from Xcode project (fallback to default)
cd "${PROJECT_DIR}/LTXVideoGenerator"
VERSION=$(xcodebuild -showBuildSettings -scheme "${SCHEME}" | grep MARKETING_VERSION | tr -d ' ' | cut -d'=' -f2 || echo "1.0.0")

if [ "$MODE" = "local-test" ]; then
    DMG_NAME="${APP_DISPLAY_NAME}-${VERSION}-local-test.dmg"
elif [ "$MODE" = "preview" ]; then
    PREVIEW_TAG="${2:-preview.12}"
    DMG_NAME="Local.Video.Studio-${VERSION}-${PREVIEW_TAG}.dmg"
else
    DMG_NAME="${APP_DISPLAY_NAME}-${VERSION}.dmg"
fi
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

echo "Version: ${VERSION}"
echo "Output: ${DMG_NAME}"
echo ""

# Clean and setup generated artifact directories only after all distribution
# credentials have passed preflight. build/ and dist/ are ignored by Git.
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

# Build the archive
echo "Building archive (Release)..."
if [ "$MODE" = "distribution" ]; then
    xcodebuild -project LTXVideoGenerator.xcodeproj \
        -scheme "${SCHEME}" \
        -configuration Release \
        -archivePath "${ARCHIVE_PATH}" \
        archive \
        PRODUCT_NAME="${APP_DISPLAY_NAME}" \
        CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
        DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}" \
        MARKETING_VERSION="${VERSION}"
else
    xcodebuild -project LTXVideoGenerator.xcodeproj \
        -scheme "${SCHEME}" \
        -configuration Release \
        -archivePath "${ARCHIVE_PATH}" \
        archive \
        PRODUCT_NAME="${APP_DISPLAY_NAME}" \
        CODE_SIGN_IDENTITY="-" \
        MARKETING_VERSION="${VERSION}"
fi

# Export the app (already correctly named from the PRODUCT_NAME override above).
echo "Exporting app..."
ditto "${ARCHIVE_PATH}/Products/Applications/${APP_DISPLAY_NAME}.app" "${APP_PATH}"

# Embed the execution-only H3 payload after export, re-sign its Mach-O files
# inside-out, then seal the outer app. No model files enter this build path.
if [ "$MODE" = "distribution" ]; then
    echo "Embedding and signing MiniMax H3 runtime payload..."
    "${PROJECT_DIR}/scripts/embed-minimax-h3-runtime.sh" \
        "${APP_PATH}" "${CODE_SIGN_IDENTITY}" distribution
else
    echo "Embedding and ad-hoc signing MiniMax H3 runtime payload..."
    "${PROJECT_DIR}/scripts/embed-minimax-h3-runtime.sh" "${APP_PATH}" "-" local
fi

# Verify signature
echo "Verifying App signature..."
codesign --verify --strict --verbose=2 "${APP_PATH}"
codesign -dv --verbose=4 "${APP_PATH}"
codesign -d --entitlements :- "${APP_PATH}"

# Notarization step for distribution
if [ "$MODE" = "distribution" ]; then
    echo "Creating notarization package..."
    ditto -c -k --keepParent "${APP_PATH}" "${BUILD_DIR}/app.zip"

    echo "Submitting App for notarization..."
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "${BUILD_DIR}/app.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_ID_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        xcrun notarytool submit "${BUILD_DIR}/app.zip" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_ID_PASSWORD}" \
            --team-id "${APPLE_TEAM_ID}" \
            --wait
    else
        echo "ERROR: Missing Notary credentials (NOTARY_PROFILE or APPLE_ID/PASSWORD/TEAM_ID)"
        exit 1
    fi

    echo "Stapling App ticket..."
    xcrun stapler staple "${APP_PATH}"
fi

# Create DMG
echo "Creating DMG..."
hdiutil create -volname "${APP_DISPLAY_NAME}" \
    -srcfolder "${APP_PATH}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

if [ "$MODE" = "distribution" ]; then
    echo "Signing DMG..."
    codesign --force --timestamp --sign "${CODE_SIGN_IDENTITY}" "${DMG_PATH}"

    echo "Notarizing DMG..."
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    else
        xcrun notarytool submit "${DMG_PATH}" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_ID_PASSWORD}" \
            --team-id "${APPLE_TEAM_ID}" \
            --wait
    fi

    echo "Stapling DMG..."
    xcrun stapler staple "${DMG_PATH}"
fi

# Verification
if [ "$MODE" = "distribution" ]; then
    echo "Verifying Distribution Artifacts..."
    codesign --verify --strict --verbose=2 "${DMG_PATH}"
    xcrun stapler validate "${APP_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    spctl -a -vv -t exec "${APP_PATH}"
    spctl -a -vv -t open "${DMG_PATH}"
fi

# Generate checksum
CHECKSUM=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
echo "${CHECKSUM}  ${DMG_NAME}" > "${DIST_DIR}/${DMG_NAME}.sha256"

echo ""
echo "=== Build Complete ==="
echo "Mode: ${MODE}"
echo "DMG: ${DMG_PATH}"
echo "SHA256: ${CHECKSUM}"
