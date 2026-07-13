import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
func read(_ path: String) throws -> String { try String(contentsOfFile: root + "/" + path, encoding: .utf8) }
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }

let bubble = try read("Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift")
let viewModel = try read("Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift")
let repository = try read("Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift")
expect(bubble.contains("internalAccess.canViewAILogs"), "日志菜单未校验内部身份")
expect(bubble.contains("internalLogs.hasLog"), "日志菜单未校验本机日志")
expect(!viewModel.contains("encodeRawLog("), "ChatViewModel 仍在编码原始日志")
expect(repository.contains("message.rawLogJSON = nil"), "Repository 仍可能写入原始日志")
print("HoloInternalLogVisibilityStandaloneTests: PASS")
