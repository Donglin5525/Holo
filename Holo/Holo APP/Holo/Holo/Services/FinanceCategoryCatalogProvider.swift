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

    private let logger = Logger(subsystem: HoloLog.subsystem, category: "FinanceCategoryCatalogProvider")
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
    /// 极简内置 catalog（后端不可用时的兜底）。
    /// 科目名按固化种子语言取三语词表（这份数据会被拿去匹配用户库里的分类、
    /// 匹配不上还会作为科目名落库展示，必须与库里的分类同语言）；
    /// 别名是微信/支付宝简体账单的匹配数据，不是显示数据，三语用户都保持简体中文不翻译。
    static func fallbackCatalog() -> FinanceCategoryCatalog {
        let language = SeedLanguage.seedLanguage
        return FinanceCategoryCatalog(
            version: 0,
            expense: [
                FinanceCategoryGroup(
                    name: FinanceSeedVocabulary.dining.value(for: language),
                    children: [
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.breakfast.value(for: language), aliases: ["早饭", "早点"], tags: ["meal", "breakfast"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.lunch.value(for: language), aliases: ["午饭", "中饭"], tags: ["meal", "lunch"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.dinner.value(for: language), aliases: ["晚饭"], tags: ["meal", "dinner"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.lateNightSnack.value(for: language), aliases: ["宵夜"], tags: ["meal", "lateNight"])
                    ]
                ),
                FinanceCategoryGroup(
                    name: FinanceSeedVocabulary.transportation.value(for: language),
                    children: [
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.taxi.value(for: language), aliases: ["出租车", "网约车", "滴滴"], tags: ["transport", "taxi"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.subway.value(for: language), aliases: ["轨道交通"], tags: ["transport", "publicTransit"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.bus.value(for: language), aliases: ["巴士"], tags: ["transport", "publicTransit"])
                    ]
                )
            ],
            income: [
                FinanceCategoryGroup(
                    name: FinanceSeedVocabulary.salaryIncome.value(for: language),
                    children: [
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.salary.value(for: language), aliases: ["薪水", "月薪", "发工资"], tags: ["income", "stableIncome"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.reimbursement.value(for: language), aliases: ["公司报销"], tags: ["income", "reimbursement"]),
                        FinanceCategoryLeaf(name: FinanceSeedVocabulary.refund.value(for: language), aliases: ["退钱"], tags: ["income", "refund"])
                    ]
                )
            ]
        )
    }
}
