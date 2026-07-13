import Foundation

@main
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
        guard condition() else { fatalError("内部诊断权限断言失败") }
    }
}
