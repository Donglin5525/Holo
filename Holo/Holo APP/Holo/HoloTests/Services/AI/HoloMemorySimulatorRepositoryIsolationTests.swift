import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloMemorySimulatorRepositoryIsolationTests.main()
    }
}
#endif
struct HoloMemorySimulatorRepositoryIsolationTests {
    private static var assertions = 0

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-memory-simulator-isolation-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let parentSentinel = applicationSupport.appendingPathComponent("keep-me.txt")
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: parentSentinel)

        guard let environment = HoloMemorySimulatorValidationEnvironment.resolve(
            environment: [
                HoloMemorySimulatorValidationEnvironment.scenarioKey:
                    HoloMemorySimulatorValidationEnvironment.supportedScenario,
                HoloMemorySimulatorValidationEnvironment.resetKey: "1"
            ],
            applicationSupportURL: applicationSupport,
            documentsURL: documents
        ) else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("应解析出模拟器场景")
            return
            #else
            fatalError("应解析出模拟器场景")
            #endif
        }

        try FileManager.default.createDirectory(
            at: environment.storeDirectoryURL,
            withIntermediateDirectories: true
        )
        let oldStore = environment.storeDirectoryURL.appendingPathComponent("old.sqlite")
        try Data("old".utf8).write(to: oldStore)
        try FileManager.default.createDirectory(
            at: environment.reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-report".utf8).write(to: environment.reportURL)

        try environment.prepareDirectories()

        expect(FileManager.default.fileExists(atPath: parentSentinel.path),
               "reset 不得删除验收根目录之外的文件")
        expect(FileManager.default.fileExists(atPath: environment.storeDirectoryURL.path),
               "reset 后必须重建场景 Store 目录")
        expect(!FileManager.default.fileExists(atPath: oldStore.path),
               "reset 必须清理上一轮 Store")
        expect(FileManager.default.fileExists(
            atPath: environment.reportURL.deletingLastPathComponent().path
        ), "reset 后必须重建报告目录")
        expect(!FileManager.default.fileExists(atPath: environment.reportURL.path),
               "reset 必须清理上一轮报告")
        expect(environment.storeDirectoryURL.path.contains("SimulatorValidation/full-chain-v2"),
               "Store 必须使用独立稳定场景路径")

        print("HoloMemorySimulatorRepositoryIsolationTests: \(assertions) assertions passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
        assertions += 1
    }
}
