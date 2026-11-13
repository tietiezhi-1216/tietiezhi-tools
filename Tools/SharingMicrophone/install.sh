#!/bin/bash
# Explicit local administrator operation only. No network access or audio restart.
set -euo pipefail
mode="${1:-}"
if [[ "$mode" != install && "$mode" != uninstall ]]; then
    echo "Usage: sudo \"$0\" install [UntitledMicrophone.driver] | uninstall" >&2
    exit 2
fi
if [[ "$EUID" -ne 0 ]]; then echo "Administrator access required; run the chosen operation explicitly with sudo." >&2; exit 1; fi
hal="/Library/Audio/Plug-Ins/HAL"
destination="$hal/UntitledMicrophone.driver"
backup_root="/Library/Application Support/com.untitled.app/AudioDriverBackups"
# Historical path is inspected only for explicit migration/removal, never loaded as an alias.
legacy_destination="$hal/TietiezhiMicrophone.driver"
for path in "/Library/Audio/Plug-Ins" "$hal" "$destination" "$legacy_destination" "/Library/Application Support/com.untitled.app" "$backup_root"; do
    if [[ -L "$path" ]]; then echo "Refusing symlink at system destination." >&2; exit 1; fi
done
validate_identity() {
    local bundle="$1" expected_id="$2" expected_executable="$3"
    [[ -f "$bundle/Contents/Info.plist" ]] || { echo "Existing driver metadata is missing; inspect it manually before retrying." >&2; return 1; }
    [[ -z "$(find "$bundle" -type l -print -quit)" ]] || { echo "Refusing symlinks in driver bundle." >&2; return 1; }
    local identifier executable
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    [[ "$identifier" == "$expected_id" && "$executable" == "$expected_executable" ]] || { echo "Unexpected driver identity; no installed driver was changed." >&2; return 1; }
}
# Validate both existing identities before moving either one.
if [[ -e "$destination" ]]; then validate_identity "$destination" com.untitled.app.microphone.driver UntitledMicrophone; fi
if [[ -e "$legacy_destination" ]]; then validate_identity "$legacy_destination" com.tietiezhi.tools.microphone.driver TietiezhiMicrophone; fi
mkdir -p "$hal" "$backup_root"
chmod 700 "$backup_root"
stage="$(mktemp -d /private/var/tmp/untitled-microphone.XXXXXX)"
chmod 700 "$stage"
backup="$(mktemp -d "$backup_root/migration.XXXXXX")"
committed=0
installed_new=0
cleanup() {
    local status=$?
    if [[ "$committed" == 0 ]]; then
        if [[ "$installed_new" == 1 && -e "$destination" ]]; then mv "$destination" "$stage/rejected.driver" || true; fi
        if [[ -e "$backup/current.driver" && ! -e "$destination" ]]; then mv "$backup/current.driver" "$destination" || true; fi
        if [[ -e "$backup/legacy.driver" && ! -e "$legacy_destination" ]]; then mv "$backup/legacy.driver" "$legacy_destination" || true; fi
        echo "Driver operation failed. Originals were restored where possible; any remaining originals are in: $backup" >&2
    fi
    rm -rf "$stage"
    if [[ -d "$backup" ]]; then rmdir "$backup" 2>/dev/null || true; fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$mode" == install ]]; then
    source="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/UntitledMicrophone.driver}"
    [[ -d "$source" ]] || { echo "Driver bundle not found: $source" >&2; exit 1; }
    # Copy into root-private staging before inspection; never execute source-bundle helpers.
    /usr/bin/ditto "$source" "$stage/UntitledMicrophone.driver"
    staged="$stage/UntitledMicrophone.driver"
    validate_identity "$staged" com.untitled.app.microphone.driver UntitledMicrophone
    /usr/bin/codesign --verify --strict "$staged"
    [[ -f "$staged/Contents/MacOS/UntitledMicrophone" ]] || exit 1
    chown -R root:wheel "$staged"
    find "$staged" -type d -exec chmod 755 {} +
    find "$staged" -type f -exec chmod 644 {} +
    chmod 755 "$staged/Contents/MacOS/UntitledMicrophone"
fi
# Move both prior identities out of HAL. EXIT rolls both back if any later step fails.
if [[ -e "$destination" ]]; then mv "$destination" "$backup/current.driver"; fi
if [[ -e "$legacy_destination" ]]; then mv "$legacy_destination" "$backup/legacy.driver"; fi
if [[ "$mode" == install ]]; then
    installed_new=1
    mv "$staged" "$destination"
fi
committed=1
if [[ "$mode" == install ]]; then
    echo "Installed Untitled Microphone. Select it again as the input device in meeting/recording apps."
else
    echo "Untitled Microphone and its historical driver were removed from HAL."
fi
echo "Restart your Mac when convenient; current audio was not restarted and default devices were not changed."
