import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath

func read(_ relativePath: String) throws -> String {
    try String(contentsOfFile: root + "/" + relativePath, encoding: .utf8)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let chat = try read("Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift")
let settings = try read("Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift")
let developerSettings = try read("Holo/Holo APP/Holo/Holo/Views/Settings/AISettingsView.swift")
let personal = try read("Holo/Holo APP/Holo/Holo/Views/Personal/PersonalView.swift")

expect(chat.contains("case aiConsent"), "聊天页缺少正式授权路由")
expect(chat.contains("AIDataProcessingConsentView()"), "聊天授权仍未使用正式授权页")
expect(chat.contains("#if DEBUG\n        case .aiSettings"), "开发 AI 设置未被 DEBUG 隔离")
expect(developerSettings.contains("#if DEBUG"), "AISettingsView 未整体放入 DEBUG 编译边界")
expect(!personal.contains("Prompt 工坊"), "个人页仍残留 Prompt 工坊死代码")
expect(settings.contains("CFBundleShortVersionString"), "关于页版本仍未读取 Bundle")
expect(settings.contains("CFBundleVersion"), "关于页 build 号仍未读取 Bundle")
print("ReleaseSettingsSurfaceStandaloneTests: PASS")
