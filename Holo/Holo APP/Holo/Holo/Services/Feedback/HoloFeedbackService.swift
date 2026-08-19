//
//  HoloFeedbackService.swift
//  Holo
//
//  用户反馈通道（设置页「反馈给开发者」）
//  调用后端 POST /v1/feedback，把反馈内容、可选截图与联系方式提交入库。
//

import Foundation
import os.log
import UIKit

/// 反馈类型。rawValue 对应后端 user_feedback.category。
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case suggestion
    case issue
    case other

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .suggestion: return "💡"
        case .issue: return "🛠"
        case .other: return "📮"
        }
    }

    var label: String {
        switch self {
        case .suggestion: return "功能建议"
        case .issue: return "问题反馈"
        case .other: return "其他"
        }
    }
}

/// 联系方式类型。rawValue 对应后端 user_feedback.contact_type。
enum FeedbackContactKind: String, CaseIterable, Identifiable {
    case wechat
    case qq
    case email
    case phone

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .wechat: return "💬"
        case .qq: return "🐧"
        case .email: return "✉️"
        case .phone: return "📱"
        }
    }

    var label: String {
        switch self {
        case .wechat: return "微信"
        case .qq: return "QQ"
        case .email: return "邮箱"
        case .phone: return "手机"
        }
    }

    var placeholder: String {
        switch self {
        case .wechat: return "微信号，方便我们找到你"
        case .qq: return "你的 QQ 号"
        case .email: return "邮箱地址，如 name@example.com"
        case .phone: return "11 位手机号"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .qq, .phone: return true
        case .wechat, .email: return false
        }
    }
}

@MainActor
final class HoloFeedbackService {

    static let shared = HoloFeedbackService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloFeedback")
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

    /// 提交一条用户反馈。
    /// - Parameters:
    ///   - category: 反馈类型。
    ///   - content: 详细描述（调用方已保证非空、≤500 字）。
    ///   - contactKind: 联系方式类型（值为空时不会上报）。
    ///   - contactValue: 联系方式内容，选填。
    ///   - images: 截图 JPEG 数据（调用方已压缩，最多 3 张）。
    ///   - appVersion / osVersion: 随反馈附带的诊断信息。
    func submit(
        category: FeedbackCategory,
        content: String,
        contactKind: FeedbackContactKind,
        contactValue: String,
        images: [Data],
        appVersion: String,
        osVersion: String
    ) async throws {
        let trimmedValue = contactValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContact = !trimmedValue.isEmpty
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/feedback",
            method: .post,
            headers: [
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: FeedbackRequest(
                category: category.rawValue,
                content: content,
                contactType: hasContact ? contactKind.rawValue : nil,
                contactValue: hasContact ? String(trimmedValue.prefix(60)) : nil,
                images: images.isEmpty ? nil : images.map { $0.base64EncodedString() },
                appVersion: appVersion,
                osVersion: osVersion
            )
        )

        let response: FeedbackResponse = try await apiClient.send(request)
        guard response.ok else {
            throw APIError.serverError("反馈提交失败，请稍后重试")
        }
        logger.info("用户反馈已提交：category=\(category.rawValue, privacy: .public) images=\(images.count, privacy: .public)")
    }
}

// MARK: - 图片压缩

enum FeedbackImageCompressor {

    /// 单张截图上限（后端 1.5MB 余量之内）
    static let maxBytes = 1_000_000

    /// 压缩截图：降采样到最长边 2400 + 循环降质直到 ≤1MB。
    /// 重绘（draw 进 renderer）同时剥离 EXIF 元数据，包括照片的 GPS 位置信息。
    static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        var quality: CGFloat = 0.75
        var output = AttachmentFileManager.compressImage(image, maxDimension: 2400, quality: quality)
        while let current = output, current.count > maxBytes, quality > 0.3 {
            quality -= 0.15
            output = AttachmentFileManager.compressImage(image, maxDimension: 2400, quality: quality)
        }
        return output
    }
}

// MARK: - DTO

private struct FeedbackRequest: Encodable {
    let category: String
    let content: String
    let contactType: String?
    let contactValue: String?
    let images: [String]?
    let appVersion: String
    let osVersion: String
}

private struct FeedbackResponse: Decodable {
    let ok: Bool
}
