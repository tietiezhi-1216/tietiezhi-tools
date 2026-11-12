#!/bin/bash
# CI only: import provided credentials; never export a local private key.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REF:-}" == refs/heads/main ]] || exit 1
keychain="$RUNNER_TEMP/untitled-signing.keychain-db"
certificate="$RUNNER_TEMP/untitled-signing.p12"
if [[ "${1:-}" == cleanup ]]; then
    if [[ -f "$keychain" ]]; then security delete-keychain "$keychain"; fi
    rm -f "$certificate" "$RUNNER_TEMP/untitled-notary.p8"
    exit 0
fi
mode="${UNTITLED_RELEASE_MODE:-preview}"
[[ "$mode" == preview || "$mode" == notarized ]] || exit 1
if [[ -z "${UNTITLED_CERTIFICATE_P12:-}" && -z "${UNTITLED_CERTIFICATE_PASSWORD:-}" ]]; then
    [[ "$mode" == preview ]] || { echo "Developer ID credentials are required." >&2; exit 1; }
    echo 'UNTITLED_SIGNING_IDENTITY=-' >> "$GITHUB_ENV"
    echo "Preparing an ad-hoc signed, unnotarized preview."
    exit 0
fi
[[ -n "${UNTITLED_CERTIFICATE_P12:-}" && -n "${UNTITLED_CERTIFICATE_PASSWORD:-}" ]] || exit 1
umask 077
printf '%s' "$UNTITLED_CERTIFICATE_P12" | base64 --decode > "$certificate"
keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -P "$UNTITLED_CERTIFICATE_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain"
identity="$(security find-identity -v -p codesigning "$keychain" | awk '/Developer ID Application:/ {print $2}')"
[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo "Expected one valid Developer ID identity." >&2; exit 1; }
echo "UNTITLED_SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
if [[ "$mode" == notarized ]]; then
    [[ -n "${UNTITLED_NOTARY_KEY:-}" && -n "${UNTITLED_NOTARY_KEY_ID:-}" ]] || exit 1
    printf '%s' "$UNTITLED_NOTARY_KEY" | base64 --decode > "$RUNNER_TEMP/untitled-notary.p8"
fi
