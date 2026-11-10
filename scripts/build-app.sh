#!/bin/zsh
# 编译并打包成 build.nosync/Silk.app。用法：scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
# 项目在 iCloud 同步的「文稿」里，带 .nosync 后缀的目录 iCloud 不会同步。
SCRATCH=".build.nosync"
OUTPUT="build.nosync/Silk.app"
# 项目目录会被文件提供程序（iCloud 等）不断给 .app/.framework/.xpc 目录加回 Finder 信息，
# codesign 不认这些附加属性，所以在临时目录里组装和签名，签好再拷回 build.nosync。
STAGE="$(mktemp -d -t silk-build)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Silk.app"

if [[ ! -f Resources/Preview/preview.js ]]; then
  echo "缺少预览页资源，先运行：cd web && npm install && npm run build" >&2
  exit 1
fi

scripts/make-icon.sh

swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"
BIN="$BIN_DIR/Silk"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build.nosync/IconAssets/Assets.car "$APP/Contents/Resources/Assets.car"
cp build.nosync/IconAssets/Silk.icns "$APP/Contents/Resources/Silk.icns"
/usr/libexec/PlistBuddy -c "Merge build.nosync/IconAssets-Info.plist" "$APP/Contents/Info.plist"
cp -R Resources/Preview "$APP/Contents/Resources/Preview"
# Sparkle 自动更新。ditto 保留框架里的软链接；框架自带签名，下面签 App 时不加 --deep，不动它。
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# build 号用提交数，没有提交时为 1。
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Quick Look 扩展。扩展必须开沙盒，读不到外面 App 包里的文件，所以预览页资源要放一份在扩展里；
# Mermaid 体积大（5 MB 多），不放，扩展里没有时再试着读 App 里的那份。先单独签扩展，再签整个 App。
APPEX="$APP/Contents/PlugIns/SilkQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
rsync -a --exclude mermaid.min.js Resources/Preview/ "$APPEX/Contents/Resources/Preview/"
cp "$BIN_DIR/SilkQuickLook" "$APPEX/Contents/MacOS/SilkQuickLook"
cp Resources/QuickLook/Info.plist "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APPEX/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPEX/Contents/Info.plist"
# 从项目目录拷出来的文件带 Finder 信息、iCloud 标记等附加属性，签名严格校验时不认，签之前清掉。
xattr -cr "$APP"
codesign --force --sign - --timestamp=none --entitlements Resources/QuickLook/SilkQuickLook.entitlements "$APPEX" >/dev/null

codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

rm -rf "$OUTPUT"
ditto "$APP" "$OUTPUT"
echo "已生成 $OUTPUT（$(du -sh "$OUTPUT" | cut -f1)）"
