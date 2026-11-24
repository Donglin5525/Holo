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
        try HoloInternalAccessStandaloneTests.main()
    }
}
#endif
struct HoloInternalAccessStandaloneTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let internalSession = HoloBackendSession(
            token: "signed-token",
            expiresAt: Int64(now.timeIntervalSince1970 + 3600),
            internalDiagnostics: true
        )
        let regularSession = HoloBackendSession(
            token: "regular-token",
            expiresAt: Int64(now.timeIntervalSince1970 + 3600),
            internalDiagnostics: false
        )
        let expiredSession = HoloBackendSession(
            token: "expired-token",
            expiresAt: Int64(now.timeIntervalSince1970 - 1),
            internalDiagnostics: true
        )

        expect(HoloInternalAccessPolicy.canViewAILogs(appleSignedIn: true, session: internalSession, now: now))
        expect(!HoloInternalAccessPolicy.canViewAILogs(appleSignedIn: true, session: regularSession, now: now))
        expect(!HoloInternalAccessPolicy.canViewAILogs(appleSignedIn: true, session: expiredSession, now: now))
        expect(!HoloInternalAccessPolicy.canViewAILogs(appleSignedIn: false, session: internalSession, now: now))
        expect(!HoloInternalAccessPolicy.canViewAILogs(appleSignedIn: true, session: nil, now: now))

        let encoded = try JSONEncoder().encode(internalSession)
        let decoded = try JSONDecoder().decode(HoloBackendSession.self, from: encoded)
        expect(decoded == internalSession)
        print("HoloInternalAccessStandaloneTests: PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool) {
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("内部诊断权限断言失败")
            return
            #else
            fatalError("内部诊断权限断言失败")
            #endif
        }
    }
}
