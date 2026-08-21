#!/bin/bash
set -euo pipefail

# Embed the exact locally accepted mlx-serve runtime into a generated .app.
# This is a packaging input, not an end-user download path. The H3 model is
# never copied by this script. Every Mach-O payload item is re-signed before
# the outer app is signed so a stale upstream signature cannot be shipped.

APP_PATH="${1:-}"
SIGN_IDENTITY="${2:--}"
SIGN_MODE="${3:-local}"
EXPECTED_VERSION="26.8.9"
EXPECTED_SOURCE_EXECUTABLE_SHA256="f1cbcdf9ee4c54a23da0a3f0f9c91e5a4d1691beb366bae9eaaa9c5c8523e60a"
DEFAULT_SOURCE="${HOME}/Library/Application Support/LocalVideoStudioDev/Runtimes/mlx-serve"
SOURCE_PATH="${MINIMAX_H3_RUNTIME_PAYLOAD_SOURCE:-${DEFAULT_SOURCE}}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -d "${APP_PATH}" ] || fail "Generated app does not exist: ${APP_PATH}"
[ -d "${SOURCE_PATH}" ] || fail "MiniMax H3 runtime payload source is missing: ${SOURCE_PATH}"

case "${SIGN_MODE}" in
    local|distribution) ;;
    *) fail "Signing mode must be local or distribution." ;;
esac

REQUIRED_FILES=(
    "mlx-serve"
    "LICENSE"
    "NOTICE"
    "LICENSE-APACHE-2.0"
    "lib/libmlx.dylib"
    "lib/libmlxc.dylib"
    "lib/libjaccl.dylib"
    "lib/libllama.dylib"
    "lib/libwebp.dylib"
    "lib/libsharpyuv.dylib"
    "lib/mlx.metallib"
)
NATIVE_FILES=(
    "mlx-serve"
    "lib/libmlx.dylib"
    "lib/libmlxc.dylib"
    "lib/libjaccl.dylib"
    "lib/libllama.dylib"
    "lib/libwebp.dylib"
    "lib/libsharpyuv.dylib"
)

for relative_path in "${REQUIRED_FILES[@]}"; do
    [ -s "${SOURCE_PATH}/${relative_path}" ] || fail "Runtime payload is missing ${relative_path}."
done
[ -x "${SOURCE_PATH}/mlx-serve" ] || fail "Runtime payload executable is not executable."

if find "${SOURCE_PATH}" -type l -print -quit | grep -q .; then
    fail "Runtime payload may not contain symbolic links."
fi

SOURCE_SHA=$(shasum -a 256 "${SOURCE_PATH}/mlx-serve" | awk '{print $1}')
[ "${SOURCE_SHA}" = "${EXPECTED_SOURCE_EXECUTABLE_SHA256}" ] || \
    fail "Runtime executable SHA-256 is not the accepted ${EXPECTED_VERSION} payload."
grep -a -q "${EXPECTED_VERSION}" "${SOURCE_PATH}/mlx-serve" || \
    fail "Runtime executable does not contain the accepted version ${EXPECTED_VERSION}."
grep -q "MIT License" "${SOURCE_PATH}/LICENSE" || fail "Runtime MIT license is missing."
grep -q "third-party" "${SOURCE_PATH}/NOTICE" || fail "Runtime NOTICE attribution is incomplete."
grep -q "Apache License" "${SOURCE_PATH}/LICENSE-APACHE-2.0" || \
    fail "Runtime Apache license text is missing."

for relative_path in "${NATIVE_FILES[@]}"; do
    lipo "${SOURCE_PATH}/${relative_path}" -verify_arch arm64 >/dev/null 2>&1 || \
        fail "Runtime component is not native arm64: ${relative_path}"
done

check_dynamic_dependencies() {
    local binary="$1"
    local install_name=""
    install_name=$(otool -D "${binary}" 2>/dev/null | tail -n 1 || true)
    while read -r dependency; do
        [ -n "${dependency}" ] || continue
        [ "${dependency}" = "${install_name}" ] && continue
        case "${dependency}" in
            @executable_path/*|@loader_path/*|@rpath/*|/System/Library/*|/usr/lib/*) ;;
            *) fail "Non-system external dependency in runtime payload: ${dependency}" ;;
        esac
    done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
}

for relative_path in "${NATIVE_FILES[@]}"; do
    check_dynamic_dependencies "${SOURCE_PATH}/${relative_path}"
done

PAYLOAD_ROOT="${APP_PATH}/Contents/Resources/MiniMaxH3Runtime"
PAYLOAD_PATH="${PAYLOAD_ROOT}/mlx-serve"

# This target is inside a newly generated build artifact only. User runtime,
# model, project and evidence directories are never touched.
rm -rf "${PAYLOAD_ROOT}"
mkdir -p "${PAYLOAD_ROOT}"
ditto --noqtn "${SOURCE_PATH}" "${PAYLOAD_PATH}"
rm -f "${PAYLOAD_PATH}/runtime_manifest.json"

PAYLOAD_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
APP_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
if [ "${SIGN_MODE}" = "distribution" ]; then
    # Developer ID gives the executable and all dylibs one Team ID, so the
    # hardened runtime's library validation succeeds normally.
    PAYLOAD_SIGN_ARGS+=(--options runtime --timestamp)
    APP_SIGN_ARGS+=(--options runtime --timestamp)
fi

# Sign dylibs before the executable, then seal the outer application last.
for relative_path in \
    "lib/libjaccl.dylib" \
    "lib/libmlx.dylib" \
    "lib/libmlxc.dylib" \
    "lib/libllama.dylib" \
    "lib/libsharpyuv.dylib" \
    "lib/libwebp.dylib"; do
    codesign "${PAYLOAD_SIGN_ARGS[@]}" "${PAYLOAD_PATH}/${relative_path}"
done
codesign "${PAYLOAD_SIGN_ARGS[@]}" "${PAYLOAD_PATH}/mlx-serve"

PACKAGED_SHA=$(shasum -a 256 "${PAYLOAD_PATH}/mlx-serve" | awk '{print $1}')
PAYLOAD_SIZE=$(du -sk "${PAYLOAD_PATH}" | awk '{print $1 * 1024}')
/usr/bin/printf '{\n  "schemaVersion": 1,\n  "runtime": "mlx-serve",\n  "runtimeVersion": "%s",\n  "architecture": "arm64",\n  "acceptedSourceExecutableSHA256": "%s",\n  "packagedExecutableSHA256": "%s",\n  "payloadBytes": %s,\n  "licenseClassification": "BUNDLE_ALLOWED",\n  "modelIncluded": false\n}\n' \
    "${EXPECTED_VERSION}" \
    "${SOURCE_SHA}" \
    "${PACKAGED_SHA}" \
    "${PAYLOAD_SIZE}" > "${PAYLOAD_ROOT}/payload_manifest.json"

for relative_path in "${NATIVE_FILES[@]}"; do
    codesign --verify --strict --verbose=2 "${PAYLOAD_PATH}/${relative_path}"
done

codesign "${APP_SIGN_ARGS[@]}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "Embedded MiniMax H3 runtime ${EXPECTED_VERSION} (arm64)."
echo "Accepted source executable SHA-256: ${SOURCE_SHA}"
echo "Packaged executable SHA-256: ${PACKAGED_SHA}"
echo "Payload bytes: ${PAYLOAD_SIZE}"
echo "Model included: NO"
