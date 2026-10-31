// 给以 SILK_DEBUG=1 启动的 Silk 发调试指令：swift scripts/debug.swift action=snapshot path=/tmp/a.png
import Foundation

var info: [String: String] = [:]
for arg in CommandLine.arguments.dropFirst() {
    guard let eq = arg.firstIndex(of: "=") else { continue }
    info[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
}
DistributedNotificationCenter.default().postNotificationName(
    .init("com.erjinzhi.silk.debug"), object: nil, userInfo: info, deliverImmediately: true
)
