//
//  HoloCloudAnalysisClient.swift
//  Holo
//
//  云端异步分析（二期 M2b）——服务端任务接口的设备侧客户端。
//  start → 上传快照 → （云端执行）→ 轮询状态/领取结果 / 取消销毁。
//  结果是「回传一次即焚」的密文交付：本客户端 GET 拿到的 result 即唯一副本。
//

import Foundation
import os.log

@MainActor
final class HoloCloudAnalysisClient {

    struct StartResponse: Decodable {
        let taskId: String
        let status: String
        let expiresAt: Double
    }

    struct StatusResponse: Decodable {
        let status: String
        let result: CloudResult?
        let failureReason: String?

        struct CloudResult: Decodable {
            let title: String?
            let claims: [CloudClaim]?
            let reasoning: String?
            let evidence: [CloudEvidence]?
            let completedAt: String?

            struct CloudClaim: Decodable {
                let summary: String?
                let displayText: String?
                let evidenceIDs: [String]?
            }

            /// 云端回传的证据原料：metric = 聚合统计口径；rows = 行明细样本
            /// （人话摘录，含备注原文）。设备端据此渲染「依据」区块。
            struct CloudEvidence: Decodable {
                let kind: String?
                let metricKey: String?
                let dataset: String?
                let group: String?
                let value: Double?
                let unit: String?
                let formula: String?
                let sourceCount: Int?
                let count: Int?
                let excerpts: [String]?
            }
        }
    }

    enum CloudAnalysisError: LocalizedError {
        case serviceDisabled
        case uploadRejected(String)

        var errorDescription: String? {
            switch self {
            case .serviceDisabled: return "云端分析暂未开放"
            case .uploadRejected(let reason): return "快照上传被拒绝：\(reason)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.holo.app", category: "CloudAnalysis")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String
    private let urlSession: URLSession

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId },
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
        self.urlSession = urlSession
    }

    private var headers: [String: String] {
        [
            "X-Holo-Device-Id": deviceIdProvider(),
            "Content-Type": "application/json",
        ]
    }

    func start(question: String) async throws -> StartResponse {
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/cloud/start",
            method: .post,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: StartBody(question: question)
        )
        do {
            return try await apiClient.send(request)
        } catch let error as APIError {
            // 503 SERVICE_DISABLED：服务未启用（密钥未配置），与瞬时故障区分开
            if case .backendError(let statusCode, _, _, _) = error, statusCode == 503 {
                throw CloudAnalysisError.serviceDisabled
            }
            throw error
        }
    }

    /// 上传快照：raw JSON 直发（后端即收即加密落存，本地不落盘明文副本）
    func uploadSnapshot(taskId: String, snapshotJSON: Data) async throws {
        guard let url = URL(string: "\(baseURL)/v1/ai/agent/cloud/\(taskId)/snapshot") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.httpBody = snapshotJSON
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.serverError("无效响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudAnalysisError.uploadRejected("HTTP \(http.statusCode)")
        }
        _ = data
    }

    func fetchStatus(taskId: String) async throws -> StatusResponse {
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/cloud/\(taskId)",
            method: .get,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: Optional<EmptyBody>.none
        )
        return try await apiClient.send(request)
    }

    /// 结果领取确认（R1）：结果已落地本地后回执，服务端销毁密文副本
    func ackResult(taskId: String) async throws {
        struct AckResponse: Decodable { let ok: Bool }
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/cloud/\(taskId)/ack",
            method: .post,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: AckBody()
        )
        let _: AckResponse = try await apiClient.send(request)
    }

    func cancel(taskId: String) async throws {
        struct CancelResponse: Decodable { let ok: Bool }
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/cloud/\(taskId)",
            method: .delete,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: Optional<EmptyBody>.none
        )
        let _: CancelResponse = try await apiClient.send(request)
    }

    /// 设备推送令牌上报（「分析完成」通知用）：token = APNs 64 位十六进制
    func registerDeviceToken(_ token: String) async throws {
        struct AckResponse: Decodable { let ok: Bool }
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/cloud/device-token",
            method: .post,
            headers: ["X-Holo-Device-Id": deviceIdProvider()],
            body: TokenBody(token: token)
        )
        let _: AckResponse = try await apiClient.send(request)
    }

    private struct StartBody: Encodable {
        let question: String
    }

    private struct TokenBody: Encodable {
        let token: String
    }

    private struct AckBody: Encodable {}

    /// GET/DELETE 无请求体的占位（APIRequest.body 无默认值）
    private struct EmptyBody: Encodable {}
}
