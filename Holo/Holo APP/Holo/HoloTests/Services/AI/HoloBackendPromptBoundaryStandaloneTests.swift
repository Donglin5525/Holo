import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
func read(_ path: String) throws -> String { try String(contentsOfFile: root + "/" + path, encoding: .utf8) }
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }

let provider = try read("Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift")
let promptService = try read("Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendPromptService.swift")
let promptManager = try read("Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift")
expect(!provider.contains("loadManagedPrompt"), "生产 Provider 仍会下载或加载托管 Prompt")
expect(!provider.contains("HoloBackendPromptService"), "生产 Provider 仍依赖 Prompt 下载服务")
expect(promptService.contains("#if DEBUG"), "Prompt 下载服务未限制在 Debug")
expect(promptManager.contains("Release 仅保留 purpose 类型标识"), "Release 未移除 Prompt 正文")
print("HoloBackendPromptBoundaryStandaloneTests: PASS")
