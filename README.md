# Silk

> Markdown, smooth as silk.

一款 macOS 原生的 Markdown 查看与编辑器，重在查看，也能随手写。面向「AI 生成了一堆 Markdown，翻起来不方便」的日常：打开文件夹就能浏览，切到对照模式就能修改。

当前版本为 `0.1.0`，处于持续开发中。以下说明对应当前源码；最低系统为 **macOS 27**，打包脚本目前生成 **Apple Silicon（arm64）** 应用。

## 功能

- **三种模式**：阅读、对照、源码。普通文件初始使用阅读模式，之后记住手动选择的模式。
- **对照编辑**：源码和预览双向滚动对齐；点击预览跳到源码，光标所在块在预览中高亮。
- **文件夹浏览**：侧栏展示 Markdown 文件及修改时间，快速打开支持按文件路径模糊查找。
- **文件夹全文搜索**：`⇧⌘F` 在整个文件夹的 Markdown 里搜索文字（不分大小写），列出每处命中所在的行；打开结果会滚到那一行并闪烁提示，对照和源码模式下同时选中命中的文字，之后在源码里按 `⌘G` 可以继续查找。
- **导出 PDF / HTML**：「文件 → 导出」把渲染好的文档存成分页 PDF，或单个独立的 HTML 文件（样式、公式字体、本地图片都嵌在文件里）。导出和打印一律使用浅色主题，折叠内容展开，图表全部画好。
- **与磁盘原文比较**：「文件 → 与磁盘版本比较…」按行列出编辑器内容与磁盘文件的差异；外部修改引起冲突时，提示条上也有「比较…」。看完可以直接选择存储自己的修改或载入磁盘版本。
- **Quick Look**：在 Finder 里选中 Markdown 文件按空格，用和阅读模式相同的渲染预览。
- **设为默认打开方式**：「Silk → 设为默认 Markdown 打开方式」一步把 `.md` 等扩展名交给 Silk 打开。
- **实时刷新**：跟随外部文件修改，尽量保留阅读位置；在文末阅读时，新增内容会继续滚动跟随。
- **草稿与恢复**：无需先选保存位置即可写作，退出后恢复文件夹、所选文件和未存走的草稿。
- **原生操作**：支持深浅色外观、最近使用的文档、源码查找与替换、打印和缩放。

### Markdown 支持

| 类型 | 支持内容 |
| --- | --- |
| 常用语法 | 标题、列表、引用、链接、图片、表格、任务列表、删除线、自动链接 |
| 扩展语法 | 脚注、`==高亮==`、内嵌 HTML、YAML / TOML 文件头 |
| 数学公式 | `$…$`、`$$…$$`、`\(…\)`、`\[…\]`，使用 KaTeX 渲染 |
| 图表与代码 | Mermaid、代码高亮、代码块复制 |
| 提示块 | GitHub 提示块（如 `> [!NOTE]`）、Obsidian callout |
| 双链 | `[[文档]]`、别名和跨文件标题锚点 |

正文中单次回车会显示为换行，空一行才分段。任务列表目前用于展示，勾选状态需在源码中修改。可以打开 [示例文档](fixtures/showcase.md) 查看渲染效果。

### 草稿与保存

首次直接启动、没有可恢复的窗口时，会打开一份空白草稿；`⌘N` 可以再建一份。草稿在停止输入约 1 秒后自动保存到 `~/Library/Application Support/Silk/Drafts/`，按 `⌘S` 再选择正式文件位置，并根据内容建议文件名。从文件夹窗口新建的草稿，存储面板默认指向该文件夹。

草稿会直接进入可编辑的模式：如果平时使用阅读模式，临时切到对照模式。关闭有内容的草稿时，可以选择存储、删除或取消；直接退出应用则保留草稿，供下次启动恢复。

普通文件在切换文件、窗口失去焦点、关闭窗口或退出应用时尝试自动保存，也可以按 `⌘S` 手动保存。外部修改与本地未保存内容发生冲突时，会提示选择保留本地修改或载入磁盘版本。

### 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建草稿 | `⌘N` |
| 打开文件或文件夹 | `⌘O` |
| 快速打开 | `⇧⌘O` |
| 存储 | `⌘S` |
| 阅读 / 对照 / 源码 | `⌘1` / `⌘2` / `⌘3` |
| 显示或隐藏侧栏 | `⌃⌘S` |
| 源码查找 / 查找并替换 | `⌘F` / `⌥⌘F` |
| 在文件夹中搜索 | `⇧⌘F` |
| 导出 PDF | `⇧⌘E` |
| 在 Finder 中显示 | `⌥⌘R` |
| 打印 | `⌘P` |
| 放大 / 缩小 / 实际大小 | `⌘+` / `⌘-` / `⌘0` |

## 开发

### 环境与构建

- macOS 27、Swift 6，以及具备 macOS 27 SDK 和 Icon Composer 编译支持的 Xcode。图标构建会调用 `xcrun actool`。
- 修改预览资源或运行前端测试时，需要 Node.js 和 npm。

以下命令均在仓库根目录执行。仓库已包含 `Resources/Preview/` 预览资源，仅修改 Swift 代码时可直接打包：

```bash
# 默认使用 release 配置；调试构建可追加 debug
scripts/build-app.sh
open build.nosync/Silk.app
```

修改 `web/` 后，先重新生成预览资源，再打包应用：

```bash
npm --prefix web ci
npm --prefix web run build
scripts/build-app.sh
```

前端构建输出到 `Resources/Preview/`，修改预览源码时需一并提交对应资源。原生构建缓存位于 `.build.nosync/`，应用产物位于 `build.nosync/`，两者均已被 Git 忽略。依赖默认安装到 `web/node_modules/`；如需使用 `.nosync` 目录和软链接，需要自行配置。

打包脚本使用本地 ad-hoc 签名，构建号取 Git 提交数。用 Xcode 打开 `Package.swift` 可以调试原生代码。

### 测试

```bash
swift test --scratch-path .build.nosync
npm --prefix web test
```

原生测试覆盖编码、保存与冲突、软链接、文件树、双链、草稿与启动恢复、文件夹搜索、差异对照、HTML 导出，以及编辑器排版和外观。预览测试覆盖增量解析与整篇解析的一致性、标题锚点和换行行为。首次运行前端测试前，先执行 `npm --prefix web ci`。

### 调试

在一个终端启动带调试接口的应用：

```bash
SILK_DEBUG=1 SILK_PROFILE=dev build.nosync/Silk.app/Contents/MacOS/Silk
```

再从另一个终端导出窗口状态或截图：

```bash
swift scripts/debug.swift action=dump path=/tmp/silk-state.txt
swift scripts/debug.swift action=snapshot path=/tmp/silk-window.png
```

调试接口还支持 `action=search query=…`（可加 `pick=N` 直接打开第 N 处结果）、`action=export format=pdf|html path=…`、`action=compare`，以及用 `action=windowSnapshot which=sheet|panel path=…` 截取表单和浮动面板。

Quick Look 扩展随应用一起打包在 `Contents/PlugIns/`。在构建目录里调试时，需要先登记扩展；若同时装了其他提供 Markdown 预览的 App（如 MarkEdit），系统可能优先用它们的扩展，可在「系统设置 → 通用 → 登录项与扩展 → Quick Look」里调整：

```bash
pluginkit -a build.nosync/Silk.app/Contents/PlugIns/SilkQuickLook.appex
qlmanage -r
qlmanage -p fixtures/showcase.md
```

扩展运行在沙盒里，读不到外面应用包里的文件，所以打包脚本会把预览资源复制一份到扩展里（不含体积较大的 Mermaid；读不到时图表显示为源码）。文档旁边的本地图片在 Quick Look 中也可能因沙盒限制而不显示。

`SILK_PROFILE` 将窗口恢复记录和草稿放到独立位置，视图模式与缩放等设置仍使用常规偏好。调试截图无需录屏权限，更多操作见 [DebugHooks.swift](Sources/Silk/DebugHooks.swift)。

### 技术结构

| 部分 | 实现 |
| --- | --- |
| 语言与界面 | Swift 6、AppKit、NSSplitViewController、NSToolbar |
| 源码编辑器 | NSTextView（TextKit 1），增量语法高亮 |
| Markdown 预览 | 常驻 WKWebView、markdown-it，按块增量更新 DOM |
| 公式与图表 | 内置 KaTeX；Mermaid 脚本按需加载 |
| 文件监听 | FSEvents |
| 导出与打印 | 预览页交出整篇 HTML，原生端内联样式、字体和图片；PDF 由不显示的 WKWebView 按纸张分页 |
| Quick Look | 沙盒 App 扩展（`Sources/SilkQuickLook/`），加载同一套预览页 |
| 应用图标 | Icon Composer 分层图标，见 [品牌资源说明](Resources/Brand/README.md) |

主要目录：`Sources/Silk/` 为原生应用，`Sources/SilkQuickLook/` 为 Quick Look 扩展，`web/src/` 为预览源码，`Resources/` 为打包资源，`Tests/SilkTests/` 和 `web/test/` 为测试，`scripts/` 为构建及调试脚本。

## 性能

优化目标：安装包小于 10 MB、冷启动小于 0.3 秒、流畅打开 5 MB 文档、打字到预览更新控制在 16 ms 内。这些是目标，尚不代表全部达成。

以下为初版 README 留存的本地测量记录（M 系列 Mac、release 构建），缺少完整基准环境记录，仅供参考，未随本次文档整理重新测量：

| 场景 | 耗时 |
| --- | --- |
| 冷启动到窗口出现 | 约 0.6 秒（进程启动起算） |
| 普通文档打字到预览更新 | 1–3 ms |
| 75 万字文档：打开 | 约 0.2 秒 |
| 75 万字文档：每次打字（原生编辑器 / 预览） | 约 9 ms / 3 ms |

预览优先重新解析改动附近的块，离视口较远的块使用等高占位，以减少大文档的解析和渲染开销。

## 后续计划

- 文件夹搜索支持正则和替换。
- 导出时可选深色主题和纸张样式。

## 项目记录

- 归属：个人项目。
- 名称：原名 Lightmark，因与已有同类 App 重名，2026-11-01 改为 Silk。
