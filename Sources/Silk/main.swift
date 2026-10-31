import AppKit

// 自定义的 NSDocumentController 必须在第一次访问 shared 之前创建。
_ = SilkDocumentController()

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
