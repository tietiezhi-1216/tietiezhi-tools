#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REF:-}" == refs/heads/main ]] || exit 1
[[ "${UNTITLED_RELEASE_MODE:-}" == notarized ]] || exit 1
app="$PWD/dist/release/Untitled.app"
archive="$RUNNER_TEMP/untitled-notarization.zip"
ditto -c -k --keepParent "$app" "$archive"
arguments=(--key "$RUNNER_TEMP/untitled-notary.p8" --key-id "$UNTITLED_NOTARY_KEY_ID")
if [[ -n "${UNTITLED_NOTARY_ISSUER:-}" ]]; then arguments+=(--issuer "$UNTITLED_NOTARY_ISSUER"); fi
xcrun notarytool submit "$archive" "${arguments[@]}" --wait --timeout 30m --output-format json > "$RUNNER_TEMP/untitled-notarization.json"
python3 - <<'PY'
import json,os,pathlib
result=json.loads((pathlib.Path(os.environ["RUNNER_TEMP"])/"untitled-notarization.json").read_text())
assert result["status"]=="Accepted", "Apple notarization did not accept the application"
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
