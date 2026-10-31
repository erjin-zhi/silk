# Silk

> Markdown, smooth as silk.

一款 macOS 原生的 Markdown 查看与编辑器，重在查看，其次编辑。目标是极致轻量、丝滑流畅，专门解决「AI 生成了一堆 Markdown，翻起来不方便」的问题。

## 为什么想做

AI 时代每天都会产生大量 Markdown 文件，Finder 里看不了，现有的编辑器要么太重，要么格式支持不全，用着都不顺手。

## 核心体验

- **重在查看**：打开文件或文件夹即渲染，默认是阅读模式。
- **自动识别各种格式**：GFM（表格、任务列表、删除线、自动链接）、脚注、数学公式（`$…$`、`$$…$$`、`\(…\)`、`\[…\]`）、Mermaid、GitHub 提示块 `> [!NOTE]`、Obsidian callout、`[[双链]]`、YAML / TOML 文件头、内嵌 HTML、代码高亮。
- **三种模式**：阅读 ⌘1 / 对照 ⌘2 / 源码 ⌘3。对照模式下左右按内容对齐滚动，点击预览跳到源码，光标所在块在预览里高亮。
- **文件夹**：侧栏只显示 Markdown 文件，快速打开 ⇧⌘O（⌘P 留给打印）。
- **实时跟随**：AI 正在改的文件，预览自动刷新，滚动位置不跳。

## 技术选型

| 部分 | 选型 |
|---|---|
| 语言 | Swift 6（严格并发） |
| 窗口、侧栏、工具栏 | AppKit：NSSplitViewController + NSToolbar，自动适配 macOS 27 的 Liquid Glass |
| 编辑器 | NSTextView（TextKit 2），只重算改动段落的语法高亮 |
| 预览 | 一个常驻 WKWebView + markdown-it，按块增量更新 DOM；KaTeX、Mermaid 用到才加载 |
| 文件监听 | FSEvents |
| 最低系统 | macOS 27 |

## 性能指标

- 安装包 < 10 MB，冷启动 < 0.3 秒
- 打开 5 MB 文件不卡，打字到预览更新在一帧（16 ms）以内

## 分期

1. **查看**：打开文件或文件夹、文件树、完整渲染、文件变化自动刷新
2. **编辑与对照**：三种模式、滚动对齐、点击跳转
3. **加分项**：Quick Look 插件、全文搜索、导出 PDF / HTML、与磁盘原文的 diff 对照

## 开发

```bash
# 构建预览页的前端资源（改了 web/ 才需要）
cd web && npm install && npm run build

# 编译并打包成 build.nosync/Silk.app
scripts/build-app.sh

# 直接运行
open build.nosync/Silk.app
```

用 Xcode 打开 `Package.swift` 可以调试。

测试：

```bash
# 原生部分：编码、保存与冲突、软链接、双链、文件树
swift test --scratch-path .build.nosync

# 预览部分：增量解析和整篇解析逐块比对、标题锚点
cd web && npm test
```

项目放在 iCloud 同步的「文稿」里，所以构建目录和 `node_modules` 都带 `.nosync` 后缀，iCloud 不会同步它们（`web/node_modules` 是指向 `node_modules.nosync` 的链接）。

调试：用 `SILK_DEBUG=1` 启动后，`swift scripts/debug.swift action=dump path=/tmp/a.txt` 能导出窗口状态，`action=snapshot` 能截图，不需要录屏权限，详见 `Sources/Silk/DebugHooks.swift`。

## 现状（第一版骨架）

已经能用：打开文件或文件夹、侧栏文件树（只显示 Markdown）、完整渲染、文件变了自动刷新（AI 往末尾追加时预览跟着滚到底）、阅读 / 对照 / 源码三种模式、对照模式双向滚动对齐和点击跳转、光标所在块高亮、⇧⌘O 快速打开、编辑自动保存（切文件、切走窗口时）、⌘P 打印、⌘+ / ⌘- 缩放。

实测（M 系列 Mac，release 构建）：

| 场景 | 耗时 |
|---|---|
| 冷启动到窗口出现 | 约 0.6 秒（进程启动起算） |
| 普通文档打字到预览更新 | 1–3 ms |
| 75 万字文档：打开 | 约 0.2 秒 |
| 75 万字文档：每次打字（原生编辑器 / 预览） | 约 9 ms / 3 ms |

大文档走两条快路径：预览只重新解析改动附近的几个块（与整篇解析逐块比对一致），离视口远的块只留等高占位。

## 项目记录

- 归属：个人项目。
- 名称：原名 Lightmark，因与已有同类 App 重名，2026-11-01 改为 Silk。
