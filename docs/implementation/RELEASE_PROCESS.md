# LTX Video Generator - Release Process

The build and release packaging is handled by `scripts/build-release.sh`.

## Packaging Modes

The script has two explicit modes. It never infers distribution intent from
ambient credentials.

### MODE 1: Local Test (`local-test`)
- **Command**: `./scripts/build-release.sh local-test`
- **Signing**: Uses ad-hoc signing (`codesign -s -`) to satisfy macOS compilation requirements. Hardened Runtime is preserved from the Xcode Archive step.
- **Notarization**: Skipped.
- **Output**: Generates a clearly marked artifact: `LTXVideoGenerator-<version>-local-test.dmg`.
- **Purpose**: Used for CI build validation, local sanity checks, and debugging without risking credential exposure or utilizing Notarytool quotas. **This artifact is NOT for distribution.**

### MODE 2: Distribution (`distribution`)
- **Command**: `CODE_SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… ./scripts/build-release.sh distribution`
- **Requirements (checked before generated artifacts are removed)**:
  - a locally valid `CODE_SIGN_IDENTITY` containing `Developer ID Application`
  - `NOTARY_PROFILE` (preferred keychain profile for notarytool) OR `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`.
- **Signing**: Uses Developer ID for the `.app` bundle and the resulting `.dmg` with Hardened Runtime enabled.
- **Notarization**: Submits the app ZIP and then the DMG with `xcrun notarytool --wait`; any non-accepted submission fails the script. `altool` is not used.
- **Stapling**: Staples the ticket to the `.app` and `.dmg`.
- **Output**: Generates `LTXVideoGenerator-<version>.dmg`.
- **Verification**: Post-build checks utilize `spctl` and `stapler validate`.

## Handling "Blocked by Credentials"

If a developer attempts to build for distribution without valid credentials, the
script **fails before touching the existing generated artifacts**. It never
falls back to ad-hoc signing. Use `local-test` explicitly when credentials are
unavailable.

## DMGs and Gatekeeper

The final artifact is a `.dmg`. Once downloaded by a user, Gatekeeper assesses
the Developer ID signature and notarization ticket. The script verifies
`codesign`, `stapler validate`, and `spctl` only in `distribution` mode.

The process follows Apple's [Developer ID](https://developer.apple.com/developer-id/)
and [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
