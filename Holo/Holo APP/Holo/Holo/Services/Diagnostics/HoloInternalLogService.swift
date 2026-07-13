#if DEBUG || INTERNAL_DIAGNOSTICS
import Combine
import Foundation
import OSLog

private let internalLogLogger = Logger(subsystem: "com.holo.app", category: "HoloInternalLog")

@MainActor
final class HoloInternalLogService: ObservableObject {
    static let shared = HoloInternalLogService()

    @Published private(set) var revision = 0

    private let store: HoloInternalLogStore
    private let urlSession: URLSession

    init(store: HoloInternalLogStore = HoloInternalLogStore(), urlSession: URLSession = .shared) {
        self.store = store
        self.urlSession = urlSession
    }

    func capture(messageId: UUID, requestIds: [String]) async {
        guard HoloInternalAccessService.shared.canViewAILogs,
              let token = HoloInternalAccessService.shared.session?.token else { return }

        var calls: [LLMCallLog] = []
        for requestId in requestIds.filter({ !$0.isEmpty }) {
            do {
                let call = try await fetchCall(requestId: requestId, token: token)
                calls.append(call)
            } catch {
                internalLogLogger.warning("内部 AI 日志拉取失败")
            }
        }
        guard !calls.isEmpty else { return }

        do {
            try store.save(HoloInternalLogRecord(
                messageId: messageId,
                requestId: requestIds.joined(separator: ","),
                capturedAt: Date(),
                log: LLMLog(calls: calls)
            ))
            revision += 1
        } catch {
            internalLogLogger.warning("内部 AI 日志本机保存失败")
        }
    }

    func hasLog(for messageId: UUID) -> Bool {
        HoloInternalAccessService.shared.canViewAILogs && store.contains(messageId: messageId)
    }

    func log(for messageId: UUID) -> LLMLog? {
        guard HoloInternalAccessService.shared.canViewAILogs else { return nil }
        return store.log(for: messageId)
    }

    func clear() {
        store.clear()
        revision += 1
    }

    private func fetchCall(requestId: String, token: String) async throws -> LLMCallLog {
        guard let url = URL(string: "\(HoloBackendEnvironment.baseURL)/v1/internal/ai-logs/\(requestId)") else {
            throw HoloInternalAccessError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HoloInternalAccessError.exchangeRejected
        }
        let payload = try JSONDecoder().decode(InternalLogResponse.self, from: data)
        let responseText = payload.log.response?.choices?.first?.message?.content
            ?? payload.log.response?.text
            ?? payload.log.error?.message
            ?? ""
        return LLMCallLog(
            requestId: requestId,
            type: payload.log.purpose,
            model: payload.log.model,
            requestMessages: payload.log.request.messages ?? [],
            responseText: responseText
        )
    }
}

private struct InternalLogResponse: Decodable {
    let log: BackendLog

    struct BackendLog: Decodable {
        let purpose: String
        let model: String
        let request: RequestPayload
        let response: ResponsePayload?
        let error: ErrorPayload?
    }

    struct RequestPayload: Decodable {
        let messages: [ChatMessageDTO]?
    }

    struct ResponsePayload: Decodable {
        let choices: [Choice]?
        let text: String?
    }

    struct Choice: Decodable { let message: ChatMessageDTO? }
    struct ErrorPayload: Decodable { let message: String? }
}
#endif
