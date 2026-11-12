#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$project_root/dist/helpers"
version=1.6.0
checksum=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
source_directory="$cache/webp-source/libwebp-$version"
webp_prefix="$cache/webp-macos14-$(uname -m)"
output="${1:-$cache/img2webp}"
if [[ ! -f "$webp_prefix/lib/libwebpmux.a" ]]; then
    mkdir -p "$cache/webp-source"
    archive="$cache/libwebp-$version.tar.gz"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 2 "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$version.tar.gz" -o "$archive.download"
        mv "$archive.download" "$archive"
    fi
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$checksum" ]]; then echo 'libwebp 下载校验失败。' >&2; exit 1; fi
    tar -xzf "$archive" -C "$cache/webp-source"
    (
        cd "$source_directory"
        # Build with the app's minimum deployment target; Homebrew libraries may target a newer OS.
        export MACOSX_DEPLOYMENT_TARGET=14.0
        sdk="$(xcrun --show-sdk-path)"
        CC="$(xcrun --find clang)" CFLAGS="-O2 -mmacosx-version-min=14.0 -isysroot $sdk" LDFLAGS="-mmacosx-version-min=14.0 -isysroot $sdk" \
            ./configure --prefix="$webp_prefix" --disable-shared --enable-static \
                --enable-libwebpmux --disable-libwebpdemux --disable-libwebpextras \
                --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif > "$cache/webp-configure.log" 2>&1
        make -j4 > "$cache/webp-make.log" 2>&1
        make install > "$cache/webp-install.log" 2>&1
    )
fi
mkdir -p "$(dirname "$output")"
xcrun clang -O2 -mmacosx-version-min=14.0 -I "$webp_prefix/include" \
    "$project_root/Tools/WebPEncoder/main.c" \
    "$webp_prefix/lib/libwebpmux.a" "$webp_prefix/lib/libwebp.a" "$webp_prefix/lib/libsharpyuv.a" \
    -framework CoreFoundation -framework CoreGraphics -framework ImageIO -o "$output"
