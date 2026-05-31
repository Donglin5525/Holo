//
//  FinanceCategoryCatalogProvider.swift
//  Holo
//
//  从后端读取标准财务科目 catalog，失败时回退到本地缓存和极简内置 catalog。
//

import Foundation
import os.log

@MainActor
final class FinanceCategoryCatalogProvider {
    static let shared = FinanceCategoryCatalogProvider()

    private let logger = Logger(subsystem: "com.holo.app", category: "FinanceCategoryCatalogProvider")
    private let baseURL: String
    private let apiClient: APIClient
    private let cache: FinanceCategoryCatalogCache
    private var memoryCache: FinanceCategoryCatalog?

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        cache: FinanceCategoryCatalogCache? = nil
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.cache = cache ?? .shared
    }

    func loadCatalog(forceRefresh: Bool = false) async -> FinanceCategoryCatalog {
        if !forceRefresh, let memoryCache {
            return memoryCache
        }

        if !forceRefresh, let cached = cache.load() {
            memoryCache = cached
            return cached
        }

        do {
            let request = APIRequest(
                baseURL: baseURL,
                path: "/v1/catalog/finance-categories",
                method: .get,
                headers: [
                    "X-Holo-Device-Id": HoloBackendDeviceIdentity.shared.deviceId
                ],
                body: nil
            )
            let remote: FinanceCategoryCatalog = try await apiClient.send(request)
            cache.save(remote)
            memoryCache = remote
            return remote
        } catch {
            logger.warning("科目 catalog 拉取失败，使用 fallback：\(error.localizedDescription)")
            let fallback = Self.fallbackCatalog()
            memoryCache = fallback
            return fallback
        }
    }

    func clearCache() {
        memoryCache = nil
        cache.clear()
    }
}

extension FinanceCategoryCatalogProvider {
    static func fallbackCatalog() -> FinanceCategoryCatalog {
        FinanceCategoryCatalog(
            version: 0,
            expense: [
                FinanceCategoryGroup(
                    name: "餐饮",
                    children: [
                        FinanceCategoryLeaf(name: "早餐", aliases: ["早饭", "早点"], tags: ["meal", "breakfast"]),
                        FinanceCategoryLeaf(name: "午餐", aliases: ["午饭", "中饭"], tags: ["meal", "lunch"]),
                        FinanceCategoryLeaf(name: "晚餐", aliases: ["晚饭"], tags: ["meal", "dinner"]),
                        FinanceCategoryLeaf(name: "夜宵", aliases: ["宵夜"], tags: ["meal", "lateNight"])
                    ]
                ),
                FinanceCategoryGroup(
                    name: "交通",
                    children: [
                        FinanceCategoryLeaf(name: "打车", aliases: ["出租车", "网约车", "滴滴"], tags: ["transport", "taxi"]),
                        FinanceCategoryLeaf(name: "地铁", aliases: ["轨道交通"], tags: ["transport", "publicTransit"]),
                        FinanceCategoryLeaf(name: "公交", aliases: ["巴士"], tags: ["transport", "publicTransit"])
                    ]
                )
            ],
            income: [
                FinanceCategoryGroup(
                    name: "工资收入",
                    children: [
                        FinanceCategoryLeaf(name: "工资", aliases: ["薪水", "月薪", "发工资"], tags: ["income", "stableIncome"]),
                        FinanceCategoryLeaf(name: "报销", aliases: ["公司报销"], tags: ["income", "reimbursement"]),
                        FinanceCategoryLeaf(name: "退款", aliases: ["退钱"], tags: ["income", "refund"])
                    ]
                )
            ]
        )
    }
}
