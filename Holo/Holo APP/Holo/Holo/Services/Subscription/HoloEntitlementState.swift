//
//  HoloEntitlementState.swift
//  Holo
//
//  会员权益的客户端展示状态；正式权益仍以服务端校验为准。
//

import Combine
import Foundation
import OSLog

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

    /// 本进程是否已完成过一次权益刷新（不论成败）。false = 冷启动空窗期：内存里的档位
    /// 只是磁盘上的旧快照（续订空档落盘的免费态、不落盘的内部验收态），Plus 门禁应等
    /// 刷新落定再判，别拿过期快照把会员拦在付费墙外。
    var hasSettledStatus = false

    private static let cacheKey = "holo.entitlement.snapshot.v1"
    private static let logger = Logger(subsystem: "com.holo.app", category: "Subscription")

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
        Self.logger.log("权益冷启动快照 plus=\(self.isPlusActive ? 1 : 0)")
    }

    func apply(status: HoloSubscriptionStatusResponse) {
        let wasPlusActive = isPlusActive
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
        if wasPlusActive != isPlusActive {
            // 档位翻转留痕：真机上「会员被当免费版」取证靠这一行
            Self.logger.log("权益档位变化 plus=\(wasPlusActive ? 1 : 0) → \(self.isPlusActive ? 1 : 0)，来源 \(String(describing: self.source), privacy: .public)")
        }
    }

    /// 一次权益刷新结束时调用（成功、失败、超时都算）
    func markStatusAttemptFinished() {
        hasSettledStatus = true
    }

    /// Plus 门禁的冷启动空窗期等待：刷新落定或超时即返回（超时后按现有快照判）
    func waitForFirstStatus(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasSettledStatus, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    #if DEBUG
    /// App Store 截图摆拍专用：本地直接按 Plus 展示，不落盘（截图模式不与服务端同步权益）。
    func applyScreenshotPlusOverride() {
        tier = .plus
        isPlusActive = true
        productId = nil
        expiresAt = nil
        quotas = HoloEntitlementState.acceptanceQuotas(for: .plus)
        source = .backend
        lastErrorMessage = nil
    }
    #endif

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
                "lifePlan": 2,
                "taskSplit": 100
            ]
            : [
                "chat": 15,
                "deepAnalysis": 1,
                "naturalLanguageFinance": 20,
                "naturalLanguageTask": 20,
                "asr": 20,
                "memoryInsight": 1,
                "lifePlan": 1,
                "taskSplit": 5
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
