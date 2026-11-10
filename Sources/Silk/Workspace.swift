import AppKit
import UniformTypeIdentifiers

enum MarkdownFiles {
    static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "mdx", "rmd", "qmd",
    ]

    /// 打开面板里允许选的类型；纯文本也能打开，按 Markdown 渲染。
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .folder]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    /// 文件树里不进去的目录：依赖、构建产物、版本库。比较时不分大小写。
    static let skippedDirectories: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "site-packages", ".pnpm-store",
        ".git", ".build", "deriveddata", "pods", "carthage",
        "__pycache__", ".venv", "venv", ".tox", ".next", ".nuxt", "target",
    ]

    /// 是不是要跳过的目录。也认 iCloud 的变体：`node_modules.nosync`（不同步的目录）、`node_modules 2`（冲突副本）。
    static func isSkippedDirectory<S: StringProtocol>(_ name: S) -> Bool {
        var base = name.lowercased()
        if base.hasSuffix(".nosync") { base.removeLast(".nosync".count) }
        // iCloud 冲突副本只加「空格 + 一两位数字」，比如「node_modules 2」。
        if let copy = base.firstMatch(of: /^(.+) \d{1,2}$/) { base = String(copy.1) }
        return skippedDirectories.contains(base)
    }

    /// 看起来是文件包（.app、.xcodeproj 等）的目录名，不进去。
    static func isPackageName(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "xcodeproj", "xcworkspace", "xcassets", "photoslibrary", "plugin", "kext", "xcarchive",
    ]

    /// FSEvents 报的路径里有没有这个文件。FSEvents 报的是真实路径（/tmp 报成 /private/tmp，软链接报成它指向的文件），
    /// 而 resolvingSymlinksInPath 会把 /private 去掉，所以用 realpath。
    static func paths(_ paths: Set<String>, mention url: URL) -> Bool {
        if paths.contains(url.path) { return true }
        guard let real = realpath(url.path, nil) else { return false }
        defer { free(real) }
        return paths.contains(String(cString: real))
    }

    /// 设默认打开方式时要改的类型：只管 .md 和 .markdown。系统每改一个类型都要弹框确认，
    /// 其他扩展名常被别的编辑器（WPS、iA Writer、Typora 等）声明成各自的类型，全改会连弹好几个框。
    static var defaultAppTypes: [UTType] {
        var types: [UTType] = []
        for type in ["md", "markdown"].compactMap({ UTType(filenameExtension: $0) })
        where !type.isDynamic && !types.contains(type) {
            types.append(type)
        }
        return types
    }

    /// .md 和 .markdown 现在是不是都用这个 App 打开。
    static func isDefaultApp(_ app: URL) -> Bool {
        let types = defaultAppTypes
        return !types.isEmpty && types.allSatisfy { isDefaultApp(app, for: $0) }
    }

    /// 这个类型现在是不是用这个 App 打开。系统按 Bundle ID 记默认 App，同一个 App 装了几份
    /// （比如 /Applications 和打包目录各一份）时，返回哪份的路径不一定，所以比 Bundle ID 而不是路径。
    static func isDefaultApp(_ app: URL, for type: UTType) -> Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        if let id = Bundle(url: app)?.bundleIdentifier, let currentID = Bundle(url: current)?.bundleIdentifier {
            return id == currentID
        }
        return current.standardizedFileURL.resolvingSymlinksInPath() == app.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

/// 文件树节点。建好后不再修改，可以安全地从后台线程交给主线程。
final class FileNode: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]

    init(url: URL, isDirectory: Bool, children: [FileNode] = []) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
    }

    /// 深度优先列出所有文件。
    var allFiles: [FileNode] {
        isDirectory ? children.flatMap(\.allFiles) : [self]
    }

    /// 扫描目录，只保留 Markdown 文件和含有 Markdown 的文件夹。
    /// 用 fts 遍历（不逐个查文件属性），几万个条目也只要零点几秒。
    nonisolated static func scan(_ root: URL) -> FileNode {
        let rootPath = root.standardizedFileURL.path
        var found: [String] = []
        var budget = 300_000  // 最多看这么多个条目，防止误开整个主目录时卡住

        guard let cRoot = strdup(rootPath) else { return FileNode(url: root, isDirectory: true) }
        defer { free(cRoot) }
        var roots: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else {
            return FileNode(url: root, isDirectory: true)
        }
        while let entry = fts_read(fts) {
            budget -= 1
            if budget <= 0 { break }
            let level = Int(entry.pointee.fts_level)
            guard level > 0 else { continue }
            let path = String(cString: entry.pointee.fts_path)
            let name = path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...]
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                if name.hasPrefix(".") || level >= 16 || MarkdownFiles.isSkippedDirectory(name)
                    || MarkdownFiles.isPackageName(name) {
                    fts_set(fts, entry, FTS_SKIP)
                }
            case FTS_F, FTS_NSOK, FTS_SL:
                if !name.hasPrefix("."), MarkdownFiles.extensions.contains(name.split(separator: ".").last.map { $0.lowercased() } ?? "") {
                    found.append(path)
                }
            default:
                break
            }
        }
        fts_close(fts)
        return buildTree(root: rootPath, files: found)
    }

    /// 由文件路径列表拼出文件树，文件夹在前，按 Finder 的方式排序。
    nonisolated private static func buildTree(root: String, files: [String]) -> FileNode {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [String] = []
        }
        let top = Folder()
        let prefixCount = root.count + (root.hasSuffix("/") ? 0 : 1)
        for path in files {
            let parts = path.dropFirst(prefixCount).split(separator: "/")
            var folder = top
            for part in parts.dropLast() {
                let key = String(part)
                if let next = folder.folders[key] { folder = next } else {
                    let next = Folder()
                    folder.folders[key] = next
                    folder = next
                }
            }
            folder.files.append(path)
        }
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        func make(_ folder: Folder, path: String) -> [FileNode] {
            let dirs = folder.folders.keys.sorted(by: order).map { name -> FileNode in
                let sub = path + "/" + name
                return FileNode(url: URL(fileURLWithPath: sub, isDirectory: true), isDirectory: true,
                                children: make(folder.folders[name]!, path: sub))
            }
            let names = folder.files.sorted { order(($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent) }
            return dirs + names.map { FileNode(url: URL(fileURLWithPath: $0, isDirectory: false), isDirectory: false) }
        }
        let rootPath = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return FileNode(url: URL(fileURLWithPath: rootPath, isDirectory: true), isDirectory: true,
                        children: make(top, path: rootPath))
    }
}

/// 一个窗口对应一个工作区：一个根目录、它的文件树和文件监听。
@MainActor
final class Workspace {
    let root: URL
    private(set) var tree: FileNode
    private(set) var files: [FileNode] = []

    /// 文件树变了（新增、删除、改名）。
    var onTreeChange: (() -> Void)?
    /// 某些文件的内容可能变了。
    var onFilesChange: ((Set<String>) -> Void)?

    private var watcher: DirectoryWatcher?
    private var rescanTask: Task<Void, Never>?
    private var rescanPending = false

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.tree = FileNode(url: root, isDirectory: true)
    }

    func start() {
        rescan(immediately: true)
        watcher = DirectoryWatcher(url: root) { [weak self] paths, structural in
            guard let self else { return }
            self.onFilesChange?(Set(paths))
            if structural { self.rescan(immediately: false) }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        rescanTask?.cancel()
    }

    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// 打开文件夹时默认显示的文件：优先 README，其次第一个文件。
    var defaultFile: URL? {
        let top = tree.children.filter { !$0.isDirectory }
        let readme = top.first { $0.name.lowercased().hasPrefix("readme") }
        return (readme ?? top.first ?? files.first)?.url
    }

    /// [[双链]] 找文件。
    func resolveWikiLink(_ name: String, from current: URL?) -> URL? {
        Self.resolveWikiLink(name, from: current, root: root, files: files.map(\.url))
    }

    /// [[双链]] 找文件：按文件名（不含扩展名、不分大小写）或「文件夹/文件名」整段匹配，
    /// 不会让 [[note]] 匹配到 subnote.md。同名的多个文件里，和当前文件同目录的优先，其次路径短的。
    nonisolated static func resolveWikiLink(_ name: String, from current: URL?, root: URL, files: [URL]) -> URL? {
        var target = name.trimmingCharacters(in: .whitespaces).lowercased()
        while target.hasPrefix("/") { target.removeFirst() }
        if MarkdownFiles.isMarkdown(URL(fileURLWithPath: target)) {
            target = (target as NSString).deletingPathExtension
        }
        guard !target.isEmpty else { return nil }

        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        let candidates = files.filter { url in
            let path = (relative(url).lowercased() as NSString).deletingPathExtension
            return path == target || path.hasSuffix("/" + target)
        }
        let currentDir = current?.deletingLastPathComponent().standardizedFileURL.path
        return candidates.min { a, b in
            let aNear = a.deletingLastPathComponent().standardizedFileURL.path == currentDir
            let bNear = b.deletingLastPathComponent().standardizedFileURL.path == currentDir
            if aNear != bNear { return aNear }
            let aDepth = relative(a).split(separator: "/").count
            let bDepth = relative(b).split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return relative(a) < relative(b)
        }
    }

    private func rescan(immediately: Bool) {
        if rescanTask != nil && !immediately {
            rescanPending = true
            return
        }
        let root = root
        rescanTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            let tree = await Task.detached(priority: .userInitiated) { FileNode.scan(root) }.value
            guard let self, !Task.isCancelled else { return }
            self.tree = tree
            self.files = tree.allFiles
            self.rescanTask = nil
            self.onTreeChange?()
            if self.rescanPending {
                self.rescanPending = false
                self.rescan(immediately: false)
            }
        }
    }
}

/// FSEvents 监听整个目录树。
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String], Bool) -> Void

    /// handler(变动的路径, 是否有增删改名)
    init(url: URL, handler: @escaping @MainActor ([String], Bool) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let structuralMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs
            )
            var structural = false
            for i in 0..<count where flags[i] & structuralMask != 0 { structural = true }
            MainActor.assumeIsolated { watcher.handler(list, structural) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
