//
//  UnderstandingConsentSweeperTests.swift
//  Holo
//
//  P1 挂账速修回归锁：授权撤销 → 影子残留（目录三件套+评审包 JSON）全清，
//  同目录其他文件不误删。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct UnderstandingConsentSweeperTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        try await clearRemovesShadowDirectoryAndReports()
        print("UnderstandingConsentSweeperTests: \(assertions) assertions passed")
    }

    static func clearRemovesShadowDirectoryAndReports() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sweeper-\(UUID().uuidString)")
        let storage = base.appendingPathComponent("UnderstandingShadow")
        let docs = base.appendingPathComponent("Documents")
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        // 影子三件套 + 评审包 + 一份无关文件
        for name in ["index.json", "themes.json", "shadow-ledger.json"] {
            try Data("{}".utf8).write(to: storage.appendingPathComponent(name))
        }
        try Data("{}".utf8).write(to: docs.appendingPathComponent("UnderstandingShadowReport-1794750575.json"))
        try Data("keep".utf8).write(to: docs.appendingPathComponent("HoloDataModel.sqlite"))

        await MainActor.run {
            UnderstandingConsentSweeper.clearShadowArtifacts(storage: storage, documents: docs)
        }

        expect(!fm.fileExists(atPath: storage.path), "影子目录整删（三件套随目录清除）")
        expect(!fm.fileExists(atPath: docs.appendingPathComponent("UnderstandingShadowReport-1794750575.json").path),
               "评审包 JSON 清除")
        expect(fm.fileExists(atPath: docs.appendingPathComponent("HoloDataModel.sqlite").path),
               "同目录无关文件不误删")
        try? fm.removeItem(at: base)
    }
}
