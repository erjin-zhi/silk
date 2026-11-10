#!/bin/zsh
# 打包一个可供自动更新的版本：编译 release、压成 zip、用 Sparkle 的 EdDSA 私钥签名、更新 appcast.xml。
#
# 用法：scripts/release.sh [--publish]
#   发版前先改 Resources/Info.plist 里的 CFBundleShortVersionString；构建号自动取提交数，必须比上一版大。
#   同目录放一份 Silk-<版本>.md 就会作为更新说明显示在更新窗口里（可选）。
#   --publish 用 gh 在 GitHub 上建 v<版本> 的 Release 并上传 zip 和 appcast.xml。
#
# 签名私钥在本机钥匙串里（第一次用 generate_keys 生成），换电脑前用
#   .build.nosync/artifacts/sparkle/Sparkle/bin/generate_keys -x 私钥文件
# 导出备份；私钥丢了，已装的 Silk 就再也收不到更新。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="${SILK_REPO:-erjin-zhi/silk}"
DIST="${SILK_RELEASE_DIR:-build.nosync/release}"
SPARKLE_BIN=".build.nosync/artifacts/sparkle/Sparkle/bin"

scripts/build-app.sh release
APP="build.nosync/Silk.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
PREFIX="${SILK_DOWNLOAD_PREFIX:-https://github.com/$REPO/releases/download/v$VERSION/}"

# DIST 里留着以前各版的 zip 和 appcast.xml，generate_appcast 只补上新的这一项。
mkdir -p "$DIST"
ZIP="$DIST/Silk-$VERSION.zip"
rm -f "$ZIP"
# --norsrc：不带附加属性，解压出来的 App 签名才完整。
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$PREFIX" \
  --maximum-deltas 0 \
  --embed-release-notes \
  "$DIST"

echo "已生成 $ZIP（构建 $BUILD）和 $DIST/appcast.xml"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES="$DIST/Silk-$VERSION.md"
  notes_args=(--generate-notes)
  [[ -f "$NOTES" ]] && notes_args=(--notes-file "$NOTES")
  gh release create "v$VERSION" "$ZIP" "$DIST/appcast.xml" \
    --repo "$REPO" --title "Silk $VERSION" "${notes_args[@]}"
  echo "已发布 https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "确认无误后上传：scripts/release.sh --publish，或手动把 zip 和 appcast.xml 传到 GitHub Release v$VERSION"
fi
