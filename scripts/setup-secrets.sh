#!/bin/bash
# Setup GitHub Secrets for Local Video Studio CI/CD
# This script helps export and configure the required secrets

set -e

REPO="${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY to owner/repository before configuring secrets.}"
CERT_NAME="${CODE_SIGN_IDENTITY:-Developer ID Application}"

echo "=== Local Video Studio - GitHub Secrets Setup ==="
echo ""

# Step 1: Export the certificate
echo "Step 1: Export Developer ID Certificate"
echo "----------------------------------------"
echo "This will export your Developer ID Application certificate."
echo "You'll need to enter your keychain password and choose a password for the .p12 file."
echo ""

# Find the certificate
CERT_SHA=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')

if [ -z "$CERT_SHA" ]; then
    echo "ERROR: Could not find Developer ID Application certificate"
    echo "Make sure you have a valid Developer ID certificate installed."
    exit 1
fi

echo "Found certificate: $CERT_NAME"
echo "SHA-1: $CERT_SHA"
echo ""

# Create temp directory
TEMP_DIR=$(mktemp -d)
P12_FILE="$TEMP_DIR/certificate.p12"

echo "Exporting certificate to: $P12_FILE"
echo "You will be prompted for:"
echo "  1. Your macOS keychain password"
echo "  2. A NEW password to protect the .p12 file (remember this!)"
echo ""

security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -o "$P12_FILE" -P ""

echo ""
echo "Certificate exported!"
echo ""

# Step 2: Base64 encode
echo "Step 2: Base64 Encode Certificate"
echo "----------------------------------"
CERT_BASE64=$(base64 -i "$P12_FILE")
echo "Certificate encoded (${#CERT_BASE64} characters)"
echo ""

# Step 3: Set GitHub secrets
echo "Step 3: Set GitHub Secrets"
echo "--------------------------"

echo "Setting APPLE_DEVELOPER_ID_CERT..."
echo "$CERT_BASE64" | gh secret set APPLE_DEVELOPER_ID_CERT -R "$REPO"

echo ""
read -s -p "Enter the password you used for the .p12 file: " CERT_PASS
echo ""
gh secret set APPLE_DEVELOPER_ID_CERT_PASSWORD -R "$REPO" -b "$CERT_PASS"
echo "Set APPLE_DEVELOPER_ID_CERT_PASSWORD"

echo ""
read -p "Enter your Apple ID email: " APPLE_ID
gh secret set APPLE_ID -R "$REPO" -b "$APPLE_ID"
echo "Set APPLE_ID"

echo ""
echo "For APPLE_ID_PASSWORD, you need an App-Specific Password:"
echo "1. Go to https://appleid.apple.com"
echo "2. Sign in and go to Sign-In and Security > App-Specific Passwords"
echo "3. Generate a new password for 'GitHub Actions'"
echo ""
read -s -p "Enter your App-Specific Password: " APP_PASS
echo ""
gh secret set APPLE_ID_PASSWORD -R "$REPO" -b "$APP_PASS"
echo "Set APPLE_ID_PASSWORD"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "All secrets configured for $REPO"
echo ""
echo "Secrets set:"
gh secret list -R "$REPO"
echo ""
echo "Release publication remains a maintainer decision; this helper does not create tags or push."
