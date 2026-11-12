#!/bin/bash
# Explicit local administrator operation only. No network access or automatic audio restart.
set -euo pipefail
mode="${1:-}"
if [[ "$mode" != install && "$mode" != uninstall ]]; then
    echo "Usage: sudo \"$0\" install [UntitledMicrophone.driver] | uninstall" >&2
    exit 2
fi
if [[ "$EUID" -ne 0 ]]; then echo "Administrator access required; run the chosen operation explicitly with sudo." >&2; exit 1; fi
hal="/Library/Audio/Plug-Ins/HAL"
destination="$hal/UntitledMicrophone.driver"
backup_root="/Library/Application Support/app.untitled/AudioDriverBackups"
if [[ -L "$hal" || -L "$destination" || -L "$backup_root" ]]; then echo "Refusing symlink at system destination." >&2; exit 1; fi
mkdir -p "$hal" "$backup_root"
chmod 700 "$backup_root"
stage="$(mktemp -d /private/var/tmp/untitled-microphone.XXXXXX)"
chmod 700 "$stage"
trap 'rm -rf "$stage"' EXIT
backup="$backup_root/$(date +%Y%m%d-%H%M%S)-$$.driver"
if [[ "$mode" == uninstall ]]; then
    if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
    echo "Driver removed from HAL. Restart your Mac when convenient; current audio was not restarted."
    exit 0
fi
source="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/UntitledMicrophone.driver}"
[[ -d "$source" ]] || { echo "Driver bundle not found: $source" >&2; exit 1; }
# Copy into root-private staging before inspecting; never execute source-bundle helpers.
/usr/bin/ditto "$source" "$stage/UntitledMicrophone.driver"
staged="$stage/UntitledMicrophone.driver"
if [[ -n "$(find "$staged" -type l -print -quit)" ]]; then echo "Refusing symlinks in driver bundle." >&2; exit 1; fi
/usr/bin/codesign --verify --strict "$staged"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staged/Contents/Info.plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staged/Contents/Info.plist")"
[[ "$identifier" == app.untitled.microphone.driver && "$executable" == UntitledMicrophone ]] || { echo "Unexpected driver identity." >&2; exit 1; }
[[ -f "$staged/Contents/MacOS/UntitledMicrophone" ]] || exit 1
chown -R root:wheel "$staged"
find "$staged" -type d -exec chmod 755 {} +
find "$staged" -type f -exec chmod 644 {} +
chmod 755 "$staged/Contents/MacOS/UntitledMicrophone"
# Migration metadata ships beside this script; no prior brand is an active code identifier.
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
migration_info="$script_directory/IdentityMigration.plist"
prefix=""
if [[ ! -f "$migration_info" ]]; then migration_info="$script_directory/../../Resources/Info.plist"; prefix="UntitledIdentityMigration:"; fi
previous_path=""; previous_backup="$backup_root/previous-$(date +%Y%m%d-%H%M%S)-$$.driver"
if [[ -f "$migration_info" ]]; then
    previous_name="$(/usr/libexec/PlistBuddy -c "Print :${prefix}driverBundle" "$migration_info")"
    previous_identifier="$(/usr/libexec/PlistBuddy -c "Print :${prefix}bundleIdentifier" "$migration_info").microphone.driver"
    [[ "$previous_name" =~ ^[A-Za-z0-9]+[.]driver$ ]] || { echo "Invalid previous driver metadata." >&2; exit 1; }
    previous_path="$hal/$previous_name"
    if [[ -e "$previous_path" && "$previous_path" != "$destination" ]]; then
        [[ ! -L "$previous_path" && -d "$previous_path" ]] || exit 1
        /usr/bin/codesign --verify --strict "$previous_path"
        actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$previous_path/Contents/Info.plist")"
        [[ "$actual" == "$previous_identifier" ]] || { echo "Previous driver identity does not match." >&2; exit 1; }
    else previous_path=""
    fi
fi
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
if [[ -n "$previous_path" ]]; then
    if ! mv "$previous_path" "$previous_backup"; then
        if [[ -e "$backup" ]]; then mv "$backup" "$destination"; fi
        exit 1
    fi
fi
if ! mv "$staged" "$destination"; then
    if [[ -e "$backup" ]]; then mv "$backup" "$destination"; fi
    if [[ -n "$previous_path" && -e "$previous_backup" ]]; then mv "$previous_backup" "$previous_path"; fi
    exit 1
fi
echo "Installed Untitled Microphone. Restart your Mac when convenient; current audio was not restarted."
echo "Then choose Untitled Microphone as input in your meeting or recording app."
