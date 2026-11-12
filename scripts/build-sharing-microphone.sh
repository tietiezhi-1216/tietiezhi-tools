#!/bin/bash
# Build only. Never installs drivers, requests administrator access, or restarts audio.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$root/dist/SharingMicrophone}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
revision="633e0f70203edd87d320fc5a3cae901e1363aac5"
checksum="204fdbff5ebb02fb485479be905a00f2147c6a283f40ced50c4029c4acfe8baf"
cache="$root/.build/sharing-microphone"
mkdir -p "$cache"
archive="$cache/libASPL-$revision.tar.gz"
if [[ ! -f "$archive" ]]; then
    temporary="$(mktemp "$cache/download.XXXXXX")"
    trap 'rm -f "${temporary:-}"' EXIT
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 120 \
        "https://api.github.com/repos/gavv/libASPL/tarball/$revision" -o "$temporary"
    printf '%s  %s\n' "$checksum" "$temporary" | shasum -a 256 -c -
    mv "$temporary" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
source="$cache/source-$revision"
if [[ ! -d "$source" ]]; then
    mkdir -p "$source"
    tar -xzf "$archive" --strip-components=1 -C "$source"
fi
stage="$(mktemp -d "$output/.build.XXXXXX")"
trap 'rm -rf "$stage"; rm -f "${temporary:-}"' EXIT
bundle="$stage/TietiezhiMicrophone.driver"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/Licenses"
cp "$root/Tools/SharingMicrophone/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/LICENSE" "$bundle/Contents/Resources/Licenses/TietiezhiTools.txt"
cp "$source/LICENSE" "$source/LICENSE.apple2012" "$source/LICENSE.apple2020" "$bundle/Contents/Resources/Licenses/"
# No CMake, Homebrew, generated-code execution, or global dependency installation is needed.
architectures="${TIETIEZHI_AUDIO_ARCHS:-$(uname -m)}"
for arch in $architectures; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    xcrun clang++ -std=c++17 -O2 -fPIC -fvisibility=hidden -Wno-reorder-init-list -mmacosx-version-min=14.0 -arch "$arch" \
        -bundle -framework CoreFoundation -framework CoreAudio -I "$source/include" \
        "$source"/src/*.cpp "$root/Tools/SharingMicrophone/Driver.cpp" -o "$stage/driver-$arch"
done
xcrun lipo -create "$stage"/driver-* -output "$bundle/Contents/MacOS/TietiezhiMicrophone"
xcrun clang++ -std=c++17 -O2 -pthread "$root/Tools/SharingMicrophone/LoopbackTests.cpp" -o "$stage/loopback-tests"
"$stage/loopback-tests"
identity="${TIETIEZHI_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$root/.signing-identity" ]]; then identity="$(tr -d '\r\n' < "$root/.signing-identity")"; fi
identity="${identity:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$bundle"
else
    codesign --force --sign "$identity" --options runtime --timestamp "$bundle"
fi
codesign --verify --strict "$bundle"
xcrun clang++ -std=c++17 -O2 -framework CoreFoundation -framework CoreAudio \
    "$root/Tools/SharingMicrophone/DriverTests.cpp" -o "$stage/driver-tests"
"$stage/driver-tests" "$bundle/Contents/MacOS/TietiezhiMicrophone"
if [[ -e "$output/TietiezhiMicrophone.driver" ]]; then mv "$output/TietiezhiMicrophone.driver" "$stage/previous.driver"; fi
if ! mv "$bundle" "$output/TietiezhiMicrophone.driver"; then
    if [[ -e "$stage/previous.driver" ]]; then mv "$stage/previous.driver" "$output/TietiezhiMicrophone.driver"; fi
    exit 1
fi
cp "$root/Tools/SharingMicrophone/install.sh" "$output/install.sh"
cp "$root/Tools/SharingMicrophone/README.md" "$output/README.md"
echo "Built: $output/TietiezhiMicrophone.driver (not installed)"
