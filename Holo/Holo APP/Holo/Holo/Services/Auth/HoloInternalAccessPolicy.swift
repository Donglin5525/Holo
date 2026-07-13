import Foundation

enum HoloInternalAccessPolicy {
    static func canViewAILogs(
        appleSignedIn: Bool,
        session: HoloBackendSession?,
        now: Date = Date()
    ) -> Bool {
        guard appleSignedIn,
              let session,
              session.internalDiagnostics,
              session.expirationDate > now,
              !session.token.isEmpty else {
            return false
        }
        return true
    }
}
