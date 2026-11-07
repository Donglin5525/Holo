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
            if let hit = Self.account(matchingCardTailIn: channel, among: accounts) {
                return .resolved(id: hit.id, name: hit.name, usedDefault: false)
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

    /// 卡尾号规则（账户解析第 1 步与「转给自己名下的卡」判定共用一处）：
    /// 文本里第一段 4 位数字作尾号，命中「账户名包含该尾号」的首个账户
    static func account(matchingCardTailIn text: String?, among accounts: [Account]) -> Account? {
        guard let text, !text.isEmpty, let tail = text.firstMatch(of: /\d{4}/)?.output else { return nil }
        return accounts.first { $0.name.contains(String(tail)) }
    }

    /// 转账对象（「招商银行(1234)」）是不是用户自己名下的卡：是 = 自己账户之间挪钱（B 类），不该记收支
    func isOwnAccount(cardText: String?) -> Bool {
        Self.account(matchingCardTailIn: cardText, among: FinanceRepository.shared.getAccounts(includeArchived: false)) != nil
    }

    // MARK: 项目解析（方案 §21.3 优先级；2026-10-04 起收支同权，收入挂项目不再是冲突）

    /// - Parameters:
    ///   - imageCandidateTexts: 理解单里的项目候选原文（merchant/summary/items，方案 §21.3 首版口径）
    ///   - caption: 用户附言
    ///   - transactionDate: 交易日期（项目周期软约束检查用）
    /// - Returns: 解析结论 + 日期越界标记（越界不拦截，转复核由门禁处理）
    func resolveProject(
        choice: ReceiptProjectChoice,
        caption: String?,
        imageCandidateTexts: [String?],
        transactionDate: Date
    ) -> (resolution: ReceiptProjectResolution, dateOutsideRange: Bool) {
        let repo = FinanceProjectRepository.shared
        let activeProjects = repo.activeProjects()

        func attached(_ project: FinanceProject) -> (ReceiptProjectResolution, Bool) {
            let outside = Self.isDate(transactionDate, outsideRangeOf: project)
            return (.resolved(id: project.id, name: project.name), outside)
        }

        switch choice {
        case .noProject:
            return (.none, false)

        case .fixed(let projectID):
            guard let project = activeProjects.first(where: { $0.id == projectID }) else {
                return (.fixedUnavailable(id: projectID), false)
            }
            return attached(project)

        case .explicitTextMatch:
            // 1. 附言精确同名唯一命中
            if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                let exact = activeProjects.filter { $0.name == caption }
                if exact.count == 1 { return attached(exact[0]) }
                if exact.count > 1 { return (.ambiguous, false) }
            }
            // 2. 图片候选（merchant/summary/items）经现有保守匹配，唯一命中才挂
            for candidate in imageCandidateTexts.compactMap({ $0 })
            where !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                let (matched, ambiguous) = FinanceProjectRepository.matchProjectCandidate(candidate, in: activeProjects)
                if let matched { return attached(matched) }
                if ambiguous { return (.ambiguous, false) }
            }
            // 3. 零命中：正常不挂项目
            return (.none, false)
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

    // MARK: 账户候选匹配（聊天记账，2026-11-01）

    /// AI 从用户话中提取的账户候选（accountCandidate，如「招商银行」「微信」）→ 用户真实账户。
    /// 精确同名（忽略大小写）> 唯一包含命中；歧义/零命中返回 nil，由调用方走默认账户。
    /// 只匹配活账户（未归档未删除）。预览展示与确认落账共用本匹配，保证卡片所示即所记。
    static func matchAccount(candidate: String?) -> Account? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        let lowered = candidate.lowercased()

        if let exact = accounts.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == lowered
        }) {
            return exact
        }

        let contains = accounts.filter {
            let name = $0.name.trimmingCharacters(in: .whitespaces).lowercased()
            return name.contains(lowered) || lowered.contains(name)
        }
        return contains.count == 1 ? contains[0] : nil
    }

    func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType,
        transferKind: String? = nil
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
            categories: categories,
            transferKind: transferKind
        )
    }

    /// 分类解析主体。孤儿分类不参与新入账，一级同名副本只在完整父级范围内兼容。
    /// transferKind：截图记账 v4 转账/红包（"transfer" | "red_packet"），非转账为 nil。
    func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType,
        categories: [Category],
        transferKind: String? = nil
    ) async -> Category? {
        let categories = FinanceCategoryIntegrity.selectableCategories(in: categories, type: type.rawValue)
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

        // 6. 转账/红包兜底（2026-11-06 转账开放方案 §2.3）：候选全落空时按「方向×类型」落种子科目。
        //    按种子三语名（SeedTerm.allValues）父子同时匹配——繁中/英文种子库对上简体候选也能命中；
        //    用户改名或删掉了这些科目则仍交调用方落「待分类」。
        if let transferKind,
           let seeded = Self.transferSeedCategory(kind: transferKind, type: type, in: categories) {
            return seeded
        }

        // 无法可靠匹配，返回 nil，由调用方使用「待分类」兜底
        return nil
    }

    /// 一级同名时允许在同名、同类型的有效父级之间查找，不跨父级语义猜测归属。
    /// 转账/红包的默认科目（方向×类型）：支出转账→其他/转账、支出红包→人情/红包礼金、
    /// 收入转账→人情来往/转入、收入红包→人情来往/红包。父子都按种子三语名匹配。
    static func transferSeedCategory(kind: String, type: TransactionType, in categories: [Category]) -> Category? {
        let isRedPacket = kind == "red_packet"
        let parentTerm: SeedTerm
        let childTerm: SeedTerm
        switch (type, isRedPacket) {
        case (.expense, false): (parentTerm, childTerm) = (FinanceSeedVocabulary.other, FinanceSeedVocabulary.transfer)
        case (.expense, true): (parentTerm, childTerm) = (FinanceSeedVocabulary.socialGifts, FinanceSeedVocabulary.cashGifts)
        case (.income, false): (parentTerm, childTerm) = (FinanceSeedVocabulary.socialIncome, FinanceSeedVocabulary.transferIn)
        case (.income, true): (parentTerm, childTerm) = (FinanceSeedVocabulary.socialIncome, FinanceSeedVocabulary.redEnvelope)
        }
        let categories = FinanceCategoryIntegrity.selectableCategories(in: categories, type: type.rawValue)
        let parentIDs = Set(categories.filter { $0.isTopLevel && parentTerm.allValues.contains($0.name) }.map(\.id))
        return categories.first {
            $0.parentId.map { parentIDs.contains($0) } == true && childTerm.allValues.contains($0.name)
        }
    }

    static func subCategory(named name: String, under parent: Category, in categories: [Category]) -> Category? {
        let categories = FinanceCategoryIntegrity.selectableCategories(in: categories, type: parent.type)
        let parentIDs = Set(categories.filter {
            $0.isTopLevel && $0.name == parent.name
        }.map(\.id))
        if let sub = categories.first(where: { $0.parentId == parent.id && $0.name == name }) {
            return sub
        }
        return categories.first(where: { $0.parentId.map { parentIDs.contains($0) } == true && $0.name == name })
    }

    /// 同上（忽略大小写变体，供 normalizedCategoryCandidate 路径）
    private static func subCategory(namedLower name: String, under parent: Category, in categories: [Category]) -> Category? {
        let categories = FinanceCategoryIntegrity.selectableCategories(in: categories, type: parent.type)
        let parentIDs = Set(categories.filter {
            $0.isTopLevel && $0.name.lowercased() == parent.name.lowercased()
        }.map(\.id))
        if let sub = categories.first(where: {
            $0.parentId == parent.id && $0.name.lowercased() == name.lowercased()
        }) {
            return sub
        }
        return categories.first(where: {
            $0.parentId.map { parentIDs.contains($0) } == true && $0.name.lowercased() == name.lowercased()
        })
    }
}
