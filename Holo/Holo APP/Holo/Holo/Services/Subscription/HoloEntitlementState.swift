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

    private init() {}

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
    }

    func setRefreshing(_ value: Bool) {
        isRefreshing = value
    }

    func setError(_ message: String?) {
        lastErrorMessage = message
    }

    private static func acceptanceQuotas(for tier: HoloSubscriptionTier) -> [String: HoloQuotaSnapshot] {
        let limits: [String: Int] = tier == .plus
            ? [
                "chat": 30,
                "naturalLanguageFinance": 50,
                "naturalLanguageTask": 50,
                "asr": 50,
                "memoryInsight": 1
            ]
            : [
                "chat": 3,
                "naturalLanguageFinance": 20,
                "naturalLanguageTask": 10,
                "asr": 20,
                "memoryInsight": 1
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

struct HoloQuotaSnapshot: Decodable, Equatable {
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
}
