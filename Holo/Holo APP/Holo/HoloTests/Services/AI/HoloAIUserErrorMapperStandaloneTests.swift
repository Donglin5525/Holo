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
        HoloAIUserErrorMapperStandaloneTests.main()
    }
}
#endif
struct HoloAIUserErrorMapperStandaloneTests {
    static func main() {
        let unsafe: [Error] = [
            APIError.decodingError(NSError(domain: "deepseek-json", code: 1)),
            APIError.httpError(statusCode: 500, message: "https://api.deepseek.com model=qwen temperature=0.8"),
            APIError.serverError("provider moonshot HTTP raw body"),
            NSError(domain: "model-secret", code: 9),
        ]
        for error in unsafe {
            let message = HoloAIUserErrorMapper.message(for: error).lowercased()
            for secret in ["deepseek", "qwen", "moonshot", "http", "temperature", "provider", "json"] {
                expect(!message.contains(secret), "用户错误泄露技术细节：\(message)")
            }
        }
        expect(HoloAIUserErrorMapper.message(for: APIError.timeout).contains("超时"), "超时文案错误")
        expect(HoloAIUserErrorMapper.message(for: APIError.rateLimited(nil)).contains("上限"), "限额文案错误")
        print("HoloAIUserErrorMapperStandaloneTests: PASS")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
}
