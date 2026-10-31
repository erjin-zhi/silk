#!/bin/zsh
# 编译 Icon Composer 分层图标，由系统处理圆角、材质和各外观。
set -euo pipefail

cd "$(dirname "$0")/.."
ICON_SOURCE="Resources/Silk.icon"
ICON_OUTPUT="build.nosync/IconAssets"
ICON_INFO="build.nosync/IconAssets-Info.plist"

if [[ ! -f "$ICON_SOURCE/icon.json" || ! -f "$ICON_SOURCE/Assets/silk-ribbon.png" ]]; then
  echo "缺少 Icon Composer 图标或前景图层：$ICON_SOURCE" >&2
  exit 1
fi

mkdir -p "$ICON_OUTPUT"
xcrun actool "$ICON_SOURCE" \
  --compile "$ICON_OUTPUT" \
  --output-format human-readable-text \
  --notices --warnings \
  --output-partial-info-plist "$ICON_INFO" \
  --app-icon Silk \
  --minimum-deployment-target 27.0 \
  --platform macosx \
  --target-device mac

echo "已生成新版 App 图标：$ICON_OUTPUT/Assets.car"
