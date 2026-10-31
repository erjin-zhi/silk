#!/bin/zsh
# 编译并打包成 build.nosync/Silk.app。用法：scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
# 项目在 iCloud 同步的「文稿」里，带 .nosync 后缀的目录 iCloud 不会同步。
SCRATCH=".build.nosync"
APP="build.nosync/Silk.app"

if [[ ! -f Resources/Preview/preview.js ]]; then
  echo "缺少预览页资源，先运行：cd web && npm install && npm run build" >&2
  exit 1
fi

scripts/make-icon.sh

swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/Silk"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build.nosync/IconAssets/Assets.car "$APP/Contents/Resources/Assets.car"
cp build.nosync/IconAssets/Silk.icns "$APP/Contents/Resources/Silk.icns"
/usr/libexec/PlistBuddy -c "Merge build.nosync/IconAssets-Info.plist" "$APP/Contents/Info.plist"
cp -R Resources/Preview "$APP/Contents/Resources/Preview"

# build 号用提交数，没有提交时为 1。
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "已生成 $APP（$(du -sh "$APP" | cut -f1)）"
