//
//  HoloAuthSessionStandaloneTests.swift
//  HoloTests
//
//  Apple 登录态模型的独立测试。
//

import Foundation

private func assertEqual(_ actual: String, _ expected: String, _ message: String) {
    guard actual == expected else {
        #if HOLO_XCTEST_BRIDGE
        XCTFail("\(message): expected \(expected), got \(actual)")
        return
        #else
        fatalError("\(message): expected \(expected), got \(actual)")
        #endif
    }
}

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
        HoloAuthSessionStandaloneTestRunner.main()
    }
}
#endif
enum HoloAuthSessionStandaloneTestRunner {
    static func main() {
        let namedSession = HoloAuthSession(
            userIdentifier: "apple-user-1",
            fullName: "  林夕  ",
            email: "lin@example.com",
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000),
            identityToken: nil
        )
        assertEqual(namedSession.displayName, "林夕", "displayName should trim Apple full name")

        let fallbackSession = HoloAuthSession(
            userIdentifier: "apple-user-2",
            fullName: "   ",
            email: nil,
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000),
            identityToken: nil
        )
        assertEqual(fallbackSession.displayName, "Apple 用户", "displayName should fall back when name is blank")
    }
}
