import AppKit

// 自定义的 NSDocumentController 必须在第一次访问 shared 之前创建。
_ = SilkDocumentController()

let app = NSApplication.shared
// 开发用：SILK_PROFILE=名字 时用独立的偏好设置和草稿目录，调试实例不会碰到平时在用的数据。
let appDelegate: AppDelegate = {
    guard let profile = ProcessInfo.processInfo.environment["SILK_PROFILE"], !profile.isEmpty else { return AppDelegate() }
    let drafts = FileManager.default.temporaryDirectory.appending(path: "silk-profile-\(profile)/Drafts")
    return AppDelegate(defaults: UserDefaults(suiteName: "com.erjinzhi.silk.profile.\(profile)")!, drafts: DraftStore(directory: drafts))
}()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
