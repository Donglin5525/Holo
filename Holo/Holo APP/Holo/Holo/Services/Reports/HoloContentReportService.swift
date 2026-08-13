//
//  HoloContentReportService.swift
//  Holo
//
//  AI 内容举报（App Store Guideline 1.2）
//  调用后端 POST /v1/reports，把用户举报的 AI 消息提交入库。
//

import Foundation
import os.log

/// 举报原因。预设项与「其他」对应后端 reason 字段。
enum ContentReportReason: String, CaseIterable, Identifiable {
    case inappropriate
    case misinformation
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inappropriate: return "包含不当内容"
        case .misinformation: return "包含错误信息"
        case .other: return "其他"
        }
    }
}

@MainActor
final class HoloContentReportService {

    static let shared = HoloContentReportService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloContentReport")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
    }

    /// 提交一条 AI 内容举报。
    /// - Parameters:
    ///   - messageId: 被举报消息的本地 UUID（客户端生成）。
    ///   - reason: 举报原因。
    ///   - detail: 可选补充说明。
    ///   - contentSnapshot: 被举报消息的正文快照，便于后台脱离客户端核对。
    func submit(
        messageId: String,
        reason: ContentReportReason,
        detail: String?,
        contentSnapshot: String?
    ) async throws {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/reports",
            method: .post,
            headers: [
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: ReportRequest(
                messageId: messageId,
                reason: reason.label,
                detail: (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil,
                contentSnapshot: contentSnapshot
            )
        )

        let response: ReportResponse = try await apiClient.send(request)
        guard response.ok else {
            throw APIError.serverError("举报提交失败，请稍后重试")
        }
        logger.info("AI 内容举报已提交：messageId=\(messageId, privacy: .public)")
    }
}

// MARK: - DTO

private struct ReportRequest: Encodable {
    let messageId: String
    let reason: String
    let detail: String?
    let contentSnapshot: String?

    enum CodingKeys: String, CodingKey {
        case messageId
        case reason
        case detail
        case contentSnapshot = "contentSnapshot"
    }
}

private struct ReportResponse: Decodable {
    let ok: Bool
}
