#!/bin/bash
# 编译 GalBox.app；只需要 Xcode 命令行工具（xcode-select --install）
# 用法: app/build.sh [输出目录]，默认 app/build；加 --install 会拷到 ~/Applications
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
INSTALL=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    *) OUT="$a" ;;
  esac
done

APP="$OUT/GalBox.app"
mkdir -p "$OUT"
if [ -d "$APP" ]; then rm -r "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/kit/bin" "$APP/Contents/Resources/kit/share"

echo "==> 编译"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/GalBox" "$HERE/GalBox.swift"

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/bin/gal" "$APP/Contents/Resources/kit/bin/gal"
chmod +x "$APP/Contents/Resources/kit/bin/gal"
cp "$ROOT/share/"* "$APP/Contents/Resources/kit/share/"

echo "==> 生成图标"
ICONSET="$OUT/GalBox.iconset"
if [ -d "$ICONSET" ]; then rm -r "$ICONSET"; fi
swift "$HERE/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/GalBox.icns"

echo "==> 签名（本机临时签名）"
codesign --force --deep -s - "$APP"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  if [ -d "$HOME/Applications/GalBox.app" ]; then rm -r "$HOME/Applications/GalBox.app"; fi
  cp -R "$APP" "$HOME/Applications/"
  # 让 Finder / Dock 认出新图标和文件类型
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/GalBox.app" || true
  echo "==> 已安装到 ~/Applications/GalBox.app"
else
  echo "==> 完成: $APP"
fi
