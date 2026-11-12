#!/bin/bash
# Explicit local administrator operation only. No network access or automatic audio restart.
set -euo pipefail
mode="${1:-}"
if [[ "$mode" != install && "$mode" != uninstall ]]; then
    echo "Usage: sudo \"$0\" install [TietiezhiMicrophone.driver] | uninstall" >&2
    exit 2
fi
if [[ "$EUID" -ne 0 ]]; then echo "Administrator access required; run the chosen operation explicitly with sudo." >&2; exit 1; fi
hal="/Library/Audio/Plug-Ins/HAL"
destination="$hal/TietiezhiMicrophone.driver"
backup_root="/Library/Application Support/com.tietiezhi.tools/AudioDriverBackups"
if [[ -L "$hal" || -L "$destination" || -L "$backup_root" ]]; then echo "Refusing symlink at system destination." >&2; exit 1; fi
mkdir -p "$hal" "$backup_root"
chmod 700 "$backup_root"
stage="$(mktemp -d /private/var/tmp/tietiezhi-microphone.XXXXXX)"
chmod 700 "$stage"
trap 'rm -rf "$stage"' EXIT
backup="$backup_root/$(date +%Y%m%d-%H%M%S)-$$.driver"
if [[ "$mode" == uninstall ]]; then
    if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
    echo "Driver removed from HAL. Restart your Mac when convenient; current audio was not restarted."
    exit 0
fi
source="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/TietiezhiMicrophone.driver}"
[[ -d "$source" ]] || { echo "Driver bundle not found: $source" >&2; exit 1; }
# Copy into root-private staging before inspecting; never execute source-bundle helpers.
/usr/bin/ditto "$source" "$stage/TietiezhiMicrophone.driver"
staged="$stage/TietiezhiMicrophone.driver"
if [[ -n "$(find "$staged" -type l -print -quit)" ]]; then echo "Refusing symlinks in driver bundle." >&2; exit 1; fi
/usr/bin/codesign --verify --strict "$staged"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staged/Contents/Info.plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staged/Contents/Info.plist")"
[[ "$identifier" == com.tietiezhi.tools.microphone.driver && "$executable" == TietiezhiMicrophone ]] || { echo "Unexpected driver identity." >&2; exit 1; }
[[ -f "$staged/Contents/MacOS/TietiezhiMicrophone" ]] || exit 1
chown -R root:wheel "$staged"
find "$staged" -type d -exec chmod 755 {} +
find "$staged" -type f -exec chmod 644 {} +
chmod 755 "$staged/Contents/MacOS/TietiezhiMicrophone"
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
if ! mv "$staged" "$destination"; then
    if [[ -e "$backup" ]]; then mv "$backup" "$destination"; fi
    exit 1
fi
echo "Installed Tietiezhi Microphone. Restart your Mac when convenient; current audio was not restarted."
echo "Then choose Tietiezhi Microphone as input in your meeting or recording app."
