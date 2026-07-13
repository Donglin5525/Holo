import Foundation

struct HoloBackendSession: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Int64
    let internalDiagnostics: Bool

    var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
}
