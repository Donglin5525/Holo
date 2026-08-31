//
//  HoloEntitlementState.swift
//  Holo
//
//  会员权益的客户端展示状态；正式权益仍以服务端校验为准。
//

import Combine
import Foundation

@MainActor
final class HoloEntitlementState: ObservableObject {
    static let shared = HoloEntitlementState()

    @Published private(set) var tier: HoloSubscriptionTier = .free
    @Published private(set) var isPlusActive = false
    @Published private(set) var productId: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var quotas: [String: HoloQuotaSnapshot] =
        HoloEntitlementState.acceptanceQuotas(for: .free)
    @Published private(set) var source: HoloEntitlementSource = .backend
    @Published private(set) var acceptanceMode: HoloAcceptanceMode = .followPurchase
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private static let cacheKey = "holo.entitlement.snapshot.v1"

    private init() {
        // 冷启动先恢复上次成功刷新的权益快照：断网/弱网冷启动时 Plus 用户
        // 不被误当免费版（付费墙误弹、语音 60 秒截断）。正式权益仍以服务端校验为准。
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CachedEntitlementSnapshot.self, from: data) {
            tier = HoloSubscriptionTier(rawValue: cached.tier) ?? .free
            isPlusActive = cached.isPlusActive
            productId = cached.productId
            expiresAt = cached.expiresAt
            quotas = cached.quotas
            source = .backend
            acceptanceMode = cached.acceptanceModeRaw.flatMap(HoloAcceptanceMode.init(rawValue:)) ?? .followPurchase
        }
    }

    func apply(status: HoloSubscriptionStatusResponse) {
        tier = HoloSubscriptionTier(rawValue: status.tier) ?? .free
        isPlusActive = status.isPlusActive
        productId = status.productId
        expiresAt = status.expiresAt.flatMap(Self.parseISODate)
        quotas = status.quotas
        source = status.source == "acceptance" ? .acceptance : .backend
        acceptanceMode = HoloAcceptanceMode(rawValue: status.acceptanceMode ?? "")
            ?? (source == .acceptance ? (tier == .plus ? .plus : .free) : .followPurchase)
        lastErrorMessage = nil
        persistSnapshotIfBackend()
    }

    /// 仅缓存正式权益；内部验收态（acceptance）不落盘，避免验收残留污染正式启动
    private func persistSnapshotIfBackend() {
        guard source == .backend else { return }
        let snapshot = CachedEntitlementSnapshot(
            tier: tier.rawValue,
            isPlusActive: isPlusActive,
            productId: productId,
            expiresAt: expiresAt,
            quotas: quotas,
            acceptanceModeRaw: acceptanceMode.rawValue
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    func setRefreshing(_ value: Bool) {
        isRefreshing = value
    }

    func setError(_ message: String?) {
        lastErrorMessage = message
    }

    /// 当前会员档位下的单条语音最长可识别秒数（客户端 ASR 时长的唯一来源）。
    /// 优先用服务端下发的 quotas["asr"].maxSeconds，兜底按档位 60/300。
    var currentAsrMaxSeconds: TimeInterval {
        if let seconds = quotas["asr"]?.maxSeconds, seconds > 0 {
            return seconds
        }
        return isPlusActive ? 300 : 60
    }

    private static func acceptanceQuotas(for tier: HoloSubscriptionTier) -> [String: HoloQuotaSnapshot] {
        // 数值与后端 quotaPolicy.js 对齐；仅为冷启动/服务端不可达时的展示兜底
        let limits: [String: Int] = tier == .plus
            ? [
                "chat": 30,
                "deepAnalysis": 10,
                "naturalLanguageFinance": 50,
                "naturalLanguageTask": 50,
                "asr": 50,
                "memoryInsight": 1,
                "lifePlan": 2
            ]
            : [
                "chat": 15,
                "deepAnalysis": 2,
                "naturalLanguageFinance": 20,
                "naturalLanguageTask": 20,
                "asr": 20,
                "memoryInsight": 1,
                "lifePlan": 1
            ]

        return limits.mapValues {
            HoloQuotaSnapshot(limit: $0, used: 0, remaining: $0)
        }
    }

    private static func parseISODate(_ value: String) -> Date? {
        isoDateFormatterWithFractionalSeconds.date(from: value) ?? isoDateFormatter.date(from: value)
    }

    private static let isoDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// 权益磁盘快照：仅用于冷启动兜底展示，服务端仍是权益唯一事实源
private struct CachedEntitlementSnapshot: Codable {
    let tier: String
    let isPlusActive: Bool
    let productId: String?
    let expiresAt: Date?
    let quotas: [String: HoloQuotaSnapshot]
    let acceptanceModeRaw: String?
}

struct HoloQuotaSnapshot: Codable, Equatable {
    let limit: Int
    let used: Int
    let remaining: Int
    let period: String?
    let resetAt: String?
    let maxSeconds: Double?

    init(
        limit: Int,
        used: Int,
        remaining: Int,
        period: String? = nil,
        resetAt: String? = nil,
        maxSeconds: Double? = nil
    ) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.period = period
        self.resetAt = resetAt
        self.maxSeconds = maxSeconds
    }
}

struct HoloSubscriptionProductsResponse: Decodable {
    let plusMonthly: String
    let plusYearly: String
}

struct HoloSubscriptionStatusResponse: Decodable {
    let tier: String
    let isPlusActive: Bool
    let productId: String?
    let expiresAt: String?
    let products: HoloSubscriptionProductsResponse
    let quotas: [String: HoloQuotaSnapshot]
    let source: String?
    let acceptanceMode: String?
    /// 服务端可控的行为开关（P2：admin 修改即生效，客户端随订阅状态刷新应用）
    let featureFlags: [String: Bool]?
}
