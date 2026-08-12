#!/bin/bash
set -e

# LTX Video Generator - Local Build Script
# This script builds, signs, notarizes, and packages the app for distribution

# Configuration
APP_NAME="LTX Video Generator"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.example.ltxvideogenerator}"
SCHEME="LTXVideoGenerator"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${SCHEME}.dmg"
DEVELOPER_ID="${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to your Developer ID Application identity.}"
TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to your Apple Developer Team ID.}"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile.}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LTX Video Generator Build Script ===${NC}"
echo "Project: ${PROJECT_DIR}"
echo ""

# Clean previous build
echo -e "${YELLOW}Cleaning previous build...${NC}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build the archive
echo -e "${YELLOW}Building archive...${NC}"
cd "${PROJECT_DIR}/LTXVideoGenerator"
xcodebuild -project LTXVideoGenerator.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID}" \
    | xcpretty || xcodebuild -project LTXVideoGenerator.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID}"

# Export the app
echo -e "${YELLOW}Exporting app from archive...${NC}"
ditto "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "${APP_PATH}"

# Verify code signature
echo -e "${YELLOW}Verifying code signature...${NC}"
codesign -dv --verbose=4 "${APP_PATH}"

# Check Gatekeeper approval (local)
echo -e "${YELLOW}Checking Gatekeeper assessment...${NC}"
spctl -a -t exec -vv "${APP_PATH}" || echo -e "${YELLOW}Note: Gatekeeper check may fail until notarized${NC}"

# Notarize the app
echo -e "${YELLOW}Submitting for notarization...${NC}"
echo "This may take several minutes..."

# Create a zip for notarization
ditto -c -k --keepParent "${APP_PATH}" "${BUILD_DIR}/app-for-notarization.zip"

# Submit for notarization
xcrun notarytool submit "${BUILD_DIR}/app-for-notarization.zip" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the notarization ticket
echo -e "${YELLOW}Stapling notarization ticket...${NC}"
xcrun stapler staple "${APP_PATH}"

# Create DMG
echo -e "${YELLOW}Creating DMG...${NC}"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${APP_PATH}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

# Sign the DMG
echo -e "${YELLOW}Signing DMG...${NC}"
codesign --force --sign "${DEVELOPER_ID}" "${DMG_PATH}"

# Notarize the DMG
echo -e "${YELLOW}Notarizing DMG...${NC}"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the DMG
xcrun stapler staple "${DMG_PATH}"

# Calculate checksum
echo -e "${YELLOW}Calculating checksum...${NC}"
CHECKSUM=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
echo "${CHECKSUM}  ${SCHEME}.dmg" > "${BUILD_DIR}/${SCHEME}.dmg.sha256"

# Final verification
echo -e "${YELLOW}Final verification...${NC}"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}"

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "App: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
echo "SHA256: ${CHECKSUM}"
echo ""
echo -e "${YELLOW}Use a maintainer-owned notarytool profile; none is configured by this repository.${NC}"
