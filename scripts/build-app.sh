#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug|release) ;;
    *) echo "用法：$0 [debug|release]" >&2; exit 1 ;;
esac

cd "$project_root"
swift build --configuration "$configuration" --product TietiezhiTools
binary_directory="$(swift build --configuration "$configuration" --show-bin-path)"
app_bundle="$project_root/dist/$configuration/Tietiezhi Tools.app"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_directory/TietiezhiTools" "$app_bundle/Contents/MacOS/TietiezhiTools"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"

# 本地开发使用临时签名；正式发布需配置自己的 Developer ID 与公证流程。
/usr/bin/codesign --force --sign - "$app_bundle"
echo "已生成：$app_bundle"
