# Silk App Icon

## 当前版本：v2（2026-11-01）

正式图标使用 macOS 新版 Icon Composer 的 `.icon` 分层资源。暖白背景铺满画布，蓝灰丝带 S 是独立透明前景；圆角、外框和深浅色/透明外观由系统生成。前景保留缎面色彩，关闭额外的玻璃材质，避免叠加高光影响辨识。

v1 将圆角白底和透明外边距画进 PNG 后导出 ICNS，实际被系统缩进另一块底板。v2 已移除这个嵌套结构，打包改为真实的 IconImageStack / IconGroup，而非把旧 PNG 简单放大。

## 文件与构建

- `../Silk.icon/icon.json`：正式图标配置，背景渐变和前景图层声明。
- `../Silk.icon/Assets/silk-ribbon.png`：1024 × 1024 RGBA 透明前景，内置 image_gen 从 v1 提取，sips 仅导出标准分辨率。
- `silk-app-icon-v2.png`、`silk-app-icon-v2-dark.png`、`silk-app-icon-v2-clear.png`：Apple ictool 的 macOS 27 默认、深色、透明浅色预览。
- `silk-app-icon-v1.png`、`silk-app-icon-v1.icns`：归档的旧版，不用于打包。
- `scripts/make-icon.sh`：用 Xcode actool 编译 `.icon`。
- `build.nosync/IconAssets/`：编译出的 `Assets.car` 和兼容 `Silk.icns`，可重新生成。
- `scripts/build-app.sh`：将图标资源和 actool 生成的 `CFBundleIconName` / `CFBundleIconFile` 一起打包。

运行 `scripts/build-app.sh` 会重新编译图标和 App。需要包含 Icon Composer 支持的 Xcode。不要将旧版 ICNS 放回 `Resources/` 或重新加手写图标 plist 键。

已验证：actool 编译成功；Assets.car 包含 Aqua、DarkAqua、Tintable 分层图标；默认、深色、透明预览通过视觉检查；重新启动后的“关于 Silk”窗口显示单层背景，无旧版内缩白框。

官方依据：[Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)（图层导出不包含圆角遮罩，背景颜色与渐变由 Icon Composer 配置）。

## 重新导出系统预览

在项目根目录执行（`--rendition` 也可设为 `Dark`、`ClearLight`）：

```sh
SILK_ICON_TOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$SILK_ICON_TOOL" Resources/Silk.icon \
  --export-image --output-file Resources/Brand/silk-app-icon-v2.png \
  --platform macOS --rendition Default \
  --width 512 --height 512 --scale 1 --design-generation 27
```

## v2 前景提取提示词

使用内置 image_gen 编辑旧版 PNG：

```text
Use case: background-extraction
Asset type: transparent foreground layer for a modern macOS Icon Composer .icon app icon.
Edit the supplied Silk icon. Extract ONLY the blue-gray silk ribbon S and remove the entire pearl-white rounded-square tile behind it, all tile borders, all exterior shadows, and all background pixels. The deliverable is one isolated S on a genuinely transparent square canvas, not a completed app icon tile.
Keep the S's silhouette, its two sweeping curves, satin blue-gray color family, front-facing orientation, smooth folded surfaces and internal highlights. Reduce the harshest glossy glints slightly so it stays restrained and calm. Preserve solid opaque ribbon surfaces and crisply antialiased edges. The holes and openings around the S must be completely transparent. No shadow behind or outside the S, no white remnants, no glow, no halo, no rounded square, no plate, no frame, no background whatsoever.
Center the S optically on the square canvas, taking about 63 percent of canvas width and 74 percent of canvas height, with equal breathing room above and below. No text or added elements. Output one clean production foreground PNG layer.
```

## v1 历史设计

以下仅记录旧版生成提示词，不作为当前 App 图标规范。


## 原始生成提示词

```text
Use case: logo-brand
Asset type: a finished macOS application icon for Silk, a lightweight native Markdown reader and editor whose promise is "Markdown, smooth as silk."
Primary request: Design one exceptionally refined, quiet, minimal app icon. The sole central mark is a broad, continuous satin ribbon forming a clearly readable capital S. The ribbon should suggest both flowing silk and the gentle turn of a reading page. Favor a strong simple S silhouette and just two graceful turns; few broad surfaces, no fine detail.
Style/medium: meticulously designed native desktop app icon, softly dimensional, precise edges, restrained depth. Elegant modern utility aesthetic, neither a cartoon nor a photorealistic fabric object. Satin has a smooth surface with NO textile weave, no wrinkles.
Color palette: pearl-white warm-gray rounded-square tile; the S uses muted slate blue #567E94, with cool pale blue highlights and deeper blue-gray folds for readable contrast. Single narrow color family.
Composition: exactly one front-facing icon, square 1024x1024 canvas. Tile centered, about 86% canvas width, with generous smooth macOS-like rounded corners. Continuous S occupies about 56% canvas width and 65% canvas height, optically centered. Outer area beyond the rounded-square tile must be genuinely transparent. Tiny soft contact shadows may stay close to tile edges. The whole icon is fully visible, never cropped.
Lighting: subtle broad top-left light, restrained soft highlights, calm matte pearl tile. Ribbon has light satin shading, sufficient dark tones to read at Dock sizes.
Constraints: a single production app icon asset, no presentation board, no mockup environment, no other variants, no extra paper-sheet pictogram, no Markdown M or arrows, no code brackets, no pen, no sparkles, no decorative lines, no wordmark, no text, no watermark, no neon, no purple gradient, no metallic chrome, no exaggerated gloss. Preserve visual simplicity and substantial negative space.
```

## 最终修订提示词

```text
Use case: precise-object-edit
Asset type: production macOS app icon with transparent outer canvas
Edit target: the supplied Silk app icon.
Keep the central blue-gray silk ribbon S exactly as designed: same shape, proportions, placement, palette and gentle satin lighting. Keep the pearl-white rounded-square tile, its scale and radius. Improve ONLY the perimeter and transparency cleanup. Remove ALL isolated specks, grain, cloudy white remnants, fringes, stray opaque pixels and shadows outside the rounded-square tile. The transparent outer margin must be perfectly empty clean alpha. The tile silhouette must be a single mathematically smooth, crisply antialiased rounded-square boundary with clean rounded corners. No exterior shadow or halo at all. Keep the tile and S entirely opaque inside the silhouette, retaining all internal highlights and internal shadows. Keep the same square composition, one icon only, no text, no other objects.
```

