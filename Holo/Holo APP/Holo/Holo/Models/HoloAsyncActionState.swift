import Foundation
import Combine

/// 显式用户操作的执行状态；调用方只在成功闭包中发布完成反馈。
@MainActor
final class HoloAsyncActionState: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    @discardableResult
    func run(_ operation: () async throws -> Void) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            try await operation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
