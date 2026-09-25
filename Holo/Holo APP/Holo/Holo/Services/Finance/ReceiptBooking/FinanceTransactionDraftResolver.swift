//
//  FinanceTransactionDraftResolver.swift
//  Holo
//
//  图片快捷指令自动记账 · 草案解析器（2026-09-14 完整方案 §6.2/§21.2/§21.3/§27.2）
//  把「理解单字段 → 分类/账户/项目」的领域解析从聊天层抽出，供所有入口共用：
//  - matchCategory 整体搬迁自 IntentRouter（抽出而非复制），IntentRouter 委托回这里，
//    文本聊天与图片识别的分类结果保持同一条链；
//  - 账户解析搬迁自 HoloVisionExtractionService.matchedAccount（尾号/关键词/默认），
//    并补充 §21.2 的显式固定选择语义；
//  - 项目解析复用 FinanceProjectRepository.matchProjectCandidate，补充 §21.3 规则。
//

import Foundation
import CoreData

// MARK: - 解析结论

enum ReceiptAccountResolution: Equatable, Sendable {
    case resolved(id: UUID, name: String, usedDefault: Bool)
    /// 用户固定的账户已归档/不存在——不得回退默认账户（方案 §21.2 禁令）
    case fixedUnavailable(id: UUID)
    /// 没有任何有效账户（needsSetup：提示先打开 Holo 创建账户）
    case noAccountAvailable
}

enum ReceiptProjectResolution: Equatable, Sendable {
    /// 不挂项目（含：explicitTextMatch 零命中）
    case none
    case resolved(id: UUID, name: String)
    /// 候选命中多个进行中项目
    case ambiguous
    /// 用户固定的项目已完结/归档/删除
    case fixedUnavailable(id: UUID)
}

// MARK: - 解析器

@MainActor
final class FinanceTransactionDraftResolver {

    static let shared = FinanceTransactionDraftResolver()

    private init() {}

    // MARK: 账户解析（方案 §21.2 优先级）

    /// 优先级：固定有效账户 > 尾号唯一命中 > 支付渠道关键词命中 > 默认账户；
    /// 禁止读手工记账页 lastSelectedAccountId，禁止凭商户猜账户。
    func resolveAccount(
        channel: String?,
        choice: ReceiptAccountChoice
    ) -> ReceiptAccountResolution {
        let repo = FinanceRepository.shared
        switch choice {
        case .fixed(let accountID):
            guard let account = repo.findAccount(by: accountID),
                  !account.isArchived,
                  account.deletedAt == nil else {
                return .fixedUnavailable(id: accountID)
            }
            return .resolved(id: account.id, name: account.name, usedDefault: false)
        case .automatic:
            let accounts = repo.getAccounts(includeArchived: false)
            guard !accounts.isEmpty else { return .noAccountAvailable }

            // 1. 尾号优先：支付通道含 4 位数字时按账户名包含尾号匹配
            if let channel, !channel.isEmpty,
               let tail = channel.firstMatch(of: /\d{4}/)?.output {
                if let hit = accounts.first(where: { $0.name.contains(String(tail)) == true }) {
                    return .resolved(id: hit.id, name: hit.name, usedDefault: false)
                }
            }
            // 2. 通道名关键词：账户名含「微信」「支付宝」「现金」等
            if let channel, !channel.isEmpty {
                let keywords = [String(localized: "微信"), String(localized: "支付宝"), String(localized: "现金")]
                for keyword in keywords where channel.contains(keyword) {
                    if let hit = accounts.first(where: { $0.name.contains(keyword) == true }) {
                        return .resolved(id: hit.id, name: hit.name, usedDefault: false)
                    }
                }
            }
            // 3. 默认账户兜底（允许自动写，但回执必须写明「默认」）
            guard let fallback = repo.getDefaultAccountSync() else {
                return .noAccountAvailable
            }
            return .resolved(id: fallback.id, name: fallback.name, usedDefault: true)
        }
    }

    // MARK: 项目解析（方案 §21.3 优先级与安全规则）

    /// - Parameters:
    ///   - imageCandidateTexts: 理解单里的项目候选原文（merchant/summary/items，方案 §21.3 首版口径）
    ///   - caption: 用户附言
    ///   - transactionDate: 交易日期（项目周期软约束检查用）
    /// - Returns: 解析结论 + 日期越界标记（越界不拦截，转复核由门禁处理）
    func resolveProject(
        choice: ReceiptProjectChoice,
        caption: String?,
        imageCandidateTexts: [String?],
        transactionDate: Date,
        typeIsIncome: Bool
    ) -> (resolution: ReceiptProjectResolution, dateOutsideRange: Bool, incomeConflict: Bool) {
        let repo = FinanceProjectRepository.shared
        let activeProjects = repo.activeProjects()

        func attached(_ project: FinanceProject) -> (ReceiptProjectResolution, Bool, Bool) {
            let outside = Self.isDate(transactionDate, outsideRangeOf: project)
            // 收入/退款不允许挂项目：显式配置不能被静默忽略（方案 §21.3）
            let incomeConflict = typeIsIncome
            return (.resolved(id: project.id, name: project.name), outside, incomeConflict)
        }

        switch choice {
        case .noProject:
            return (.none, false, false)

        case .fixed(let projectID):
            guard let project = activeProjects.first(where: { $0.id == projectID }) else {
                return (.fixedUnavailable(id: projectID), false, false)
            }
            return attached(project)

        case .explicitTextMatch:
            // 1. 附言精确同名唯一命中
            if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                let exact = activeProjects.filter { $0.name == caption }
                if exact.count == 1 { return attached(exact[0]) }
                if exact.count > 1 { return (.ambiguous, false, false) }
            }
            // 2. 图片候选（merchant/summary/items）经现有保守匹配，唯一命中才挂
            for candidate in imageCandidateTexts.compactMap({ $0 })
            where !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                let (matched, ambiguous) = FinanceProjectRepository.matchProjectCandidate(candidate, in: activeProjects)
                if let matched { return attached(matched) }
                if ambiguous { return (.ambiguous, false, false) }
            }
            // 3. 零命中：正常不挂项目
            return (.none, false, false)
        }
    }

    /// 项目日期是软约束：越界返回 true（门禁转复核，用户仍可手工确认挂靠）
    static func isDate(_ date: Date, outsideRangeOf project: FinanceProject) -> Bool {
        if let start = project.startDate, date < start { return true }
        if let end = project.endDate, date > end { return true }
        return false
    }

    // MARK: 分类解析（自 IntentRouter.matchCategory 整体搬迁，2026-09-15）
    // 链路：用户纠正学习 → AI 标准科目 → 本地自定义 + catalog 别名 → 语义兜底 → note/原始候选精确 → 待分类
    // 语义变更必须同时过聊天识图回归与本目录单测。

    func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType
    ) async throws -> Category? {
        let categories = try await FinanceRepository.shared.getCategories(by: type)
        return await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note,
            type: type,
            categories: categories
        )
    }

    /// 分类解析主体（categories 注入版）。独立出来供单测构造孤儿/一级重复等
    /// 异常库形态（2026-09-25 酸汤肥牛落待分类治理：真实库的父子挂接断裂
    /// 曾让全部按 parentId 的子类查找失配，静默掉进「待分类」）。
    func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType,
        categories: [Category]
    ) async -> Category? {
        let candidates = CategoryCandidateResolver.orderedCandidates(
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note,
            hour: Calendar.current.component(.hour, from: Date())
        )

        // 1. 用户学习映射最优先，尊重手动纠正过的分类
        for candidate in candidates {
            if let learned = CategoryLearnedMapping.lookup(
                candidate: candidate,
                type: type,
                primaryCategory: primaryCategory ?? ""
            ) ?? CategoryLearnedMapping.lookup(candidate: candidate, type: type) {

                // 仅当用户映射到的二级本身是餐次（早/午/晚/夜宵）时，才按当前时间动态重算餐段；
                // 否则尊重用户明确映射的具体品类（如"奶茶→饮品""星巴克→咖啡"），不做时段覆盖
                if CategoryCandidateResolver.mealSlotSubCategories.contains(learned.sub) {
                    let hour = Calendar.current.component(.hour, from: Date())
                    let mealSub = CategoryCandidateResolver.mealSubCategoryForHour(hour)
                    let parent = categories.first(where: {
                        $0.isTopLevel && $0.name == learned.primary && $0.type == type.rawValue
                    })
                    if let parent = parent,
                       let sub = Self.subCategory(named: mealSub, under: parent, in: categories) {
                        return sub
                    }
                }

                // 非餐次映射（具体品类或其他一级）：走精确匹配，尊重用户映射
                let learnedResult = CategoryMatcherService.shared.matchSingle(
                    primaryCategory: learned.primary,
                    subCategory: learned.sub,
                    type: type,
                    categories: categories
                )
                if let matched = learnedResult.matchedCategory, matched.isSubCategory {
                    return matched
                }
            }
        }

        // 2. AI 明确给出的标准科目，走严格 Core Data 匹配
        if let sub = subCategory, !sub.isEmpty {
            let matchResult = CategoryMatcherService.shared.matchSingle(
                primaryCategory: primaryCategory ?? "",
                subCategory: sub,
                type: type,
                categories: categories
            )
            if matchResult.matchType == .exact || matchResult.matchType == .synonym,
               let matched = matchResult.matchedCategory,
               matched.isSubCategory {
                return matched
            }
        }

        // 3. 本地科目 + catalog 别名
        for candidate in candidates {
            // 直接匹配用户本地已有科目，保护自定义分类
            if let customMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
                candidate,
                primaryCategory: primaryCategory ?? "",
                type: type,
                categories: categories
            ) {
                return customMatched
            }

            // 标准 catalog 负责别名归一，例如"滴滴"→"交通/打车"
            let catalog = await FinanceCategoryCatalogProvider.shared.loadCatalog()
            if let catalogMatch = CategoryMatcherService.shared.matchCandidate(candidate, type: type, catalog: catalog) {
                let catalogResult = CategoryMatcherService.shared.matchSingle(
                    primaryCategory: catalogMatch.primaryCategory,
                    subCategory: catalogMatch.subCategory,
                    type: type,
                    categories: categories
                )
                if let matched = catalogResult.matchedCategory, matched.isSubCategory {
                    return matched
                }
            }
        }

        // 3.5. AI 语义兜底：semanticCategoryHint 匹配到一级分类后推断二级
        if let hint = semanticCategoryHint?.trimmingCharacters(in: .whitespaces),
           !hint.isEmpty {
            let hintLower = hint.lowercased()
            if let parent = categories.first(where: {
                $0.isTopLevel && $0.type == type.rawValue && $0.name.lowercased() == hintLower
            }) {
                if CategoryCandidateResolver.timeSensitivePrimaries.contains(parent.name) {
                    // 餐饮类：按时间选餐段
                    let hour = Calendar.current.component(.hour, from: Date())
                    let mealSub = CategoryCandidateResolver.mealSubCategoryForHour(hour)
                    if let sub = Self.subCategory(named: mealSub, under: parent, in: categories) {
                        return sub
                    }
                } else {
                    // 非餐饮类：用 normalizedCategoryCandidate 在该一级分类下找子类
                    if let normalized = normalizedCategoryCandidate?.trimmingCharacters(in: .whitespaces),
                       !normalized.isEmpty {
                        if let sub = Self.subCategory(namedLower: normalized, under: parent, in: categories) {
                            return sub
                        }
                    }
                }
            }
        }

        // 4. 降级：note 只做唯一精确匹配
        if let noteMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
            note,
            primaryCategory: "",
            type: type,
            categories: categories
        ) {
            return noteMatched
        }

        // 5. 原始 candidate 再做一次直接匹配，避免餐饮归一掩盖同名自定义分类
        if let rawCandidate = categoryCandidate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidates.contains(rawCandidate),
           let rawMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
                rawCandidate,
                primaryCategory: primaryCategory ?? "",
                type: type,
                categories: categories
           ) {
            return rawMatched
        }

        // 无法可靠匹配，返回 nil，由调用方使用「待分类」兜底
        return nil
    }

    /// 子类查找：优先按 parentId 挂接关系；挂接断裂（孤儿子类/一级分类重复导致
    /// first 拿到的 parent 不是子类实际挂靠的那条）时退化为同名子类——
    /// 「实体在、名字对」的库仍能落位，不静默掉进「待分类」
    static func subCategory(named name: String, under parent: Category, in categories: [Category]) -> Category? {
        if let sub = categories.first(where: { $0.parentId == parent.id && $0.name == name }) {
            return sub
        }
        return categories.first(where: { $0.isSubCategory && $0.name == name })
    }

    /// 同上（忽略大小写变体，供 normalizedCategoryCandidate 路径）
    private static func subCategory(namedLower name: String, under parent: Category, in categories: [Category]) -> Category? {
        if let sub = categories.first(where: {
            $0.parentId == parent.id && $0.name.lowercased() == name.lowercased()
        }) {
            return sub
        }
        return categories.first(where: {
            $0.isSubCategory && $0.name.lowercased() == name.lowercased()
        })
    }
}
