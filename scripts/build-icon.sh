#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$project_root/Resources/AppIcon.icns}"
source_image="$project_root/Resources/Brand/AppIcon.png"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/untitled-icon.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
iconset="$staging_directory/AppIcon.iconset"
mkdir -p "$iconset"

# 只缩放用户选定的原图，不重新绘制、裁切或改变构图。
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
        pixels=$((size * scale))
        /usr/bin/sips -z "$pixels" "$pixels" "$source_image" \
            --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
/usr/bin/iconutil --convert icns "$iconset" --output "$staging_directory/AppIcon.icns"
mkdir -p "$(dirname "$output")"
mv "$staging_directory/AppIcon.icns" "$output"
echo "已生成：$output"
