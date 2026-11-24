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
        HoloMemorySimulatorValidationEnvironmentTests.main()
    }
}
#endif
struct HoloMemorySimulatorValidationEnvironmentTests {
    private static var assertions = 0

    static func main() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/holo-app-support")
        let documents = URL(fileURLWithPath: "/tmp/holo-documents")

        expect(
            HoloMemorySimulatorValidationEnvironment.resolve(
                environment: [:],
                applicationSupportURL: applicationSupport,
                documentsURL: documents
            ) == nil,
            "无场景参数时必须关闭"
        )
        expect(
            HoloMemorySimulatorValidationEnvironment.resolve(
                environment: [
                    HoloMemorySimulatorValidationEnvironment.scenarioKey: "unknown"
                ],
                applicationSupportURL: applicationSupport,
                documentsURL: documents
            ) == nil,
            "不支持的场景必须拒绝"
        )

        for resetValue in ["1", "true", "TRUE", "YES", "yes"] {
            let resolved = resolve(
                reset: resetValue,
                applicationSupport: applicationSupport,
                documents: documents
            )
            expect(resolved?.shouldReset == true, "reset=\(resetValue) 应解析为 true")
        }

        let resolved = resolve(
            reset: "0",
            applicationSupport: applicationSupport,
            documents: documents
        )
        expect(resolved?.scenario == "full-chain-v2", "场景名必须稳定")
        expect(resolved?.shouldReset == false, "reset=0 应解析为 false")
        expect(
            resolved?.storeDirectoryURL.path ==
                "/tmp/holo-app-support/Holo/SimulatorValidation/full-chain-v2",
            "Store 必须位于固定的模拟器验收目录"
        )
        expect(
            resolved?.reportURL.path ==
                "/tmp/holo-documents/HoloMemoryValidation/full-chain-v2.json",
            "报告必须位于 Documents 固定路径"
        )
        expect(
            resolved?.storeDirectoryURL.lastPathComponent == resolved?.scenario,
            "场景目录不得使用随机 UUID"
        )

        print("HoloMemorySimulatorValidationEnvironmentTests: \(assertions) assertions passed")
    }

    private static func resolve(
        reset: String,
        applicationSupport: URL,
        documents: URL
    ) -> HoloMemorySimulatorValidationEnvironment? {
        HoloMemorySimulatorValidationEnvironment.resolve(
            environment: [
                HoloMemorySimulatorValidationEnvironment.scenarioKey:
                    HoloMemorySimulatorValidationEnvironment.supportedScenario,
                HoloMemorySimulatorValidationEnvironment.resetKey: reset
            ],
            applicationSupportURL: applicationSupport,
            documentsURL: documents
        )
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
