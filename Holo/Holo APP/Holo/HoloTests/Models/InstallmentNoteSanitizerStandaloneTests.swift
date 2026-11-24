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
        InstallmentNoteSanitizerStandaloneTests.main()
    }
}
#endif
struct InstallmentNoteSanitizerStandaloneTests {
    static func main() {
        expect(InstallmentNoteSanitizer.clean("[分期 1/12] 智谱 max") == "智谱 max", "应移除单个旧前缀")
        expect(
            InstallmentNoteSanitizer.clean("[分期 2/12] [分期 1/12] [分期 1/12] 智谱 max") == "智谱 max",
            "应一次移除重复叠加的旧前缀"
        )
        expect(InstallmentNoteSanitizer.clean("智谱 max") == "智谱 max", "正常商品名称不应变化")
        expect(InstallmentNoteSanitizer.clean("[分期 1/12]") == nil, "仅含分期前缀时应视为空名称")
        expect(InstallmentNoteSanitizer.clean(nil) == nil, "空名称应保持为空")
        print("InstallmentNoteSanitizerStandaloneTests passed")
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
    }
}
