import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath

func read(_ relativePath: String) throws -> String {
    try String(contentsOfFile: root + "/" + relativePath, encoding: .utf8)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func expectGuarded(_ source: String, marker: String, file: String) {
    guard let markerRange = source.range(of: marker) else {
        fatalError("\(file) 缺少内部诊断标记：\(marker)")
    }

    let prefix = source[..<markerRange.lowerBound]
    guard let guardRange = prefix.range(
        of: "#if DEBUG || INTERNAL_DIAGNOSTICS",
        options: .backwards
    ) else {
        fatalError("\(file) 的 \(marker) 未放入内部构建条件")
    }

    let between = source[guardRange.upperBound..<markerRange.lowerBound]
    expect(!between.contains("#endif"), "\(file) 的 \(marker) 位于内部构建条件之外")

    let suffix = source[markerRange.upperBound...]
    expect(suffix.contains("#endif"), "\(file) 的 \(marker) 缺少条件编译闭合")
}

let guardedMarkers: [(String, [String])] = [
    ("Holo/Holo APP/Holo/Holo/Services/Auth/HoloInternalAccessService.swift", [
        "final class HoloInternalAccessService"
    ]),
    ("Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogService.swift", [
        "final class HoloInternalLogService"
    ]),
    ("Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogStore.swift", [
        "final class HoloInternalLogStore"
    ]),
    ("Holo/Holo APP/Holo/Holo/Views/Chat/ChatLogView.swift", [
        "struct ChatLogView"
    ]),
    ("Holo/Holo APP/Holo/Holo/Services/Auth/AppleSignInAuthService.swift", [
        "private let internalAccessService",
        "internalAccessService.establishSession",
        "internalAccessService.clear()"
    ]),
    ("Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift", [
        "@State private var viewingLog",
        "ChatLogView(log:",
        "HoloInternalLogService.shared.log"
    ]),
    ("Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift", [
        "HoloInternalLogService.shared.capture"
    ]),
    ("Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift", [
        "HoloInternalAccessService.shared",
        "HoloInternalLogService.shared",
        "Label(\"查看日志\""
    ])
]

for (file, markers) in guardedMarkers {
    let source = try read(file)
    for marker in markers {
        expectGuarded(source, marker: marker, file: file)
    }
}

let consent = try read("Holo/Holo APP/Holo/Holo/Views/Settings/AIDataProcessingConsentView.swift")
expect(consent.contains("财务、习惯、待办、观点和健康摘要"), "AI 授权页未明确列出可能发送的数据类别")
expect(consent.contains("语音片段"), "AI 授权页未说明语音片段会发送给第三方服务")

let reviewNotes = try read("docs/app-store/review-notes-and-metadata.md")
expect(!reviewNotes.contains("When prompted in AI Settings"), "审核步骤仍引用 Release 中不存在的 AI Settings")
expect(!reviewNotes.contains("TODO："), "审核材料仍有未完成占位符")

print("HoloInternalDiagnosticsBuildBoundaryStandaloneTests: PASS")
