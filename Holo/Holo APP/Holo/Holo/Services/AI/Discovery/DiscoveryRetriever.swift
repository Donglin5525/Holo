//
//  DiscoveryRetriever.swift
//  Holo
//
//  「HoloAI 一个发现」G2：初次召回 + 反例召回（02 §3 触发材料与召回 / §6 反例检索）。
//
//  纯本地，零网络：不调 embedding 接口，不新增外部向量库（02 §3.2 末段）。
//  V1 召回三通道：显式关系（标签/主题/目标锚）+ 关键词（CONTAINS[cd] 交权限谓词）
//  + 限定时间窗扫描。所有 fetch 经适配器与 basePredicate 求交（回源核权）。
//
//  · 召回顺序（§3.2 初值）：变化对象及明确关联 → 近 30 自然日同主题 →
//    需要比较时定向 90 天同对象历史 → 预留反例预算。
//  · 预算：候选材料 ≤24 块（生成阶段 ≤12 块，余量留历史与反例），每块 ≤400 字（builder 保证）。
//  · 反例（§6）：每候选 ≤3 条受限查询（domain/anchor/keyword——时间由程序固定全窗口，
//    不接受模型自定时间）；越界查询（路径/URL/未授权域）整条拒绝并标检索不完整；
//    程序侧中性回看必须执行（同对象/同主题全窗口扫描，防「证实自己」查询漏反例）；
//    每候选反例块 ≤6，三候选合并去重受总包预算约束；
//    覆盖三态严格区分：搜索完成无命中 / 索引或历史不足 / 预算截断。
//  · 核版本：revalidate 对冻结 atom 回源重取，sourceRevision 变化或来源消失即失效
//    （变了不用旧块）。
//

import Foundation

// MARK: - 初次召回结果

/// 初次召回材料包（进入候选生成前的完整支持材料）。
struct DiscoveryMaterialPackage: Equatable, Sendable {
    /// 采用的支持块（≤ Limits.totalBlocks；末位附 1 个 computedFact atom）
    let supportAtoms: [DiscoveryFactAtom]
    /// 生成阶段材料（≤ Limits.generationBlocks；调用一输入的匿名 evidence 集）
    let generationEvidenceIDs: [String]
    let coverage: DiscoveryFactAtom.Coverage
    /// 反例预留预算（块数 = 24 − 已用支持块）
    let counterBudgetBlocks: Int
}

// MARK: - 反例覆盖三态（§6 末段）

/// 反例检索覆盖状态。「没有命中」不等于「找不到反例」——三态必须严格区分并记录。
enum DiscoveryCounterCoverageState: String, Equatable, Sendable {
    /// 搜索完成且有命中（未截断）
    case complete
    /// 搜索完成且无命中（当前记录范围内没有；仍只说当前记录范围）
    case completedNoHit
    /// 没有可用索引／历史不足（不能发布广泛模式）
    case insufficientHistoryOrIndex
    /// 预算截断（coverageIncomplete；repeat/change 默认不发布）
    case budgetTruncated
}

/// 反例包。
struct DiscoveryCounterPackage: Equatable, Sendable {
    /// 反例/补充块（≤ Limits.perCandidateCounterBlocks；不含支持块重复）
    let blocks: [DiscoveryFactAtom]
    let coverageState: DiscoveryCounterCoverageState
    /// 越界查询整条拒绝数（≥1 ⇒ 检索不完整，coverageIncomplete）
    let rejectedQueryCount: Int
    /// 程序侧中性回看是否执行（§6：必须执行，不只按模型建议检索）
    let neutralLookbackExecuted: Bool
}

// MARK: - 核版本结果

/// 冻结 atom 回源核版本的失效标记（G4 发布前 / G6 提交前用）。
struct DiscoveryStaleEvidence: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        /// 原文/参与字段已变化（sourceRevision 不一致）
        case revisionChanged
        /// 来源消失或不再可见（核权谓词求交后取不到）
        case sourceMissing
    }

    let evidenceID: String
    let sourceRef: String
    let reason: Reason
}

// MARK: - Retriever

struct DiscoveryRetriever {

    /// 预算常量（02 §3.2）
    enum Limits {
        static let totalBlocks = 24
        static let generationBlocks = 12
        static let perCandidateCounterBlocks = 6
        static let maxCounterQueriesPerCandidate = 3
        /// 召回单通道 fetch 上限（快照数；块预算另算）
        static let channelFetchLimit = 40
    }

    /// 反例信号词表（确定性排序依据：会推翻核心解释的块优先保留）
    static let counterSignalLexicon: [String] = [
        "但是", "不过", "然而", "还是没", "没有继续", "后来", "取消", "其实",
        "反而", "没做到", "失败", "不行", "停止", "中断", "放弃了", "不是",
    ]

    private let adapters: [any DiscoverySourceAdapting]
    private let policy = DiscoveryAccessPolicy()

    init(adapters: [any DiscoverySourceAdapting]) {
        self.adapters = adapters
    }

    // MARK: - 请求

    struct Request: Sendable {
        /// 变化对象（"thought:<uuid>" / "task:<uuid>" / "habitEvent:<uuid>"）
        var changedSourceRefs: [String] = []
        /// 额外主题线索（"tag:名" / "topic:<uuid>" / "goal:<uuid>"）
        var topicRefs: [String] = []
        /// 变化类候选需要比较 → 定向召回近 90 天同对象历史
        var needsComparisonHistory = false
        var comparisonAnchorRefs: [String] = []
        /// 自然日语义（保存本次时区与确切区间 [start,end)，02 §3.2）
        var calendar: Calendar

        init(
            changedSourceRefs: [String] = [],
            topicRefs: [String] = [],
            needsComparisonHistory: Bool = false,
            comparisonAnchorRefs: [String] = [],
            calendar: Calendar
        ) {
            self.changedSourceRefs = changedSourceRefs
            self.topicRefs = topicRefs
            self.needsComparisonHistory = needsComparisonHistory
            self.comparisonAnchorRefs = comparisonAnchorRefs
            self.calendar = calendar
        }
    }

    // MARK: - 初次召回

    func initialRecall(
        request: Request,
        environment: DiscoveryAccessSnapshot,
        now: Date
    ) throws -> DiscoveryMaterialPackage {
        let builder = DiscoveryEvidenceBuilder()
        let granted = try grantedAdapters(environment: environment)
        guard !granted.isEmpty else {
            // 无授权域：空包（门控上游已拒；此处兜底为空结果而非报错）
            let coverage = DiscoveryFactAtom.Coverage(
                domains: [], windowStart: nil, windowEnd: nil,
                matchedCount: 0, usedCount: 0, truncatedCount: 0,
                denominatorKnown: true, indexVersion: nil
            )
            return DiscoveryMaterialPackage(
                supportAtoms: [], generationEvidenceIDs: [], coverage: coverage, counterBudgetBlocks: 0
            )
        }

        let windows = Self.windows(for: request, now: now)
        let scanWindow = request.needsComparisonHistory ? windows.history : windows.topic

        // 通道 1：变化对象（按 kind 前缀路由到对应适配器）
        var merged: [DiscoverySourceSnapshot] = []
        var seenRefs = Set<String>()
        func absorb(_ snapshots: [DiscoverySourceSnapshot]) {
            for snapshot in snapshots where !seenRefs.contains(snapshot.sourceRefCanonical) {
                seenRefs.insert(snapshot.sourceRefCanonical)
                merged.append(snapshot)
            }
        }
        let changedByKind = Dictionary(grouping: request.changedSourceRefs, by: { String($0.prefix(while: { $0 != ":" })) })
        for adapter in granted {
            let kindPrefix = adapter.sourceKind.rawValue
            let localIDs = (changedByKind[kindPrefix] ?? [])
                .map { String($0.dropFirst(kindPrefix.count + 1)) }
                .filter { !$0.isEmpty }
            if !localIDs.isEmpty {
                absorb(try adapter.fetchSnapshots(localIDs: localIDs, limit: Limits.channelFetchLimit))
            }
        }

        // 通道 2：近 30 自然日同主题（变化对象的显式关联 + 请求主题线索）
        let topicRefs = merged.flatMap(\.entityRefs) + request.topicRefs
        if !topicRefs.isEmpty {
            for adapter in granted {
                absorb(try adapter.fetchSnapshots(topicRefs: topicRefs, window: windows.topic, limit: Limits.channelFetchLimit))
            }
        }

        // 通道 3：需要比较时，定向召回近 90 天同对象历史
        if request.needsComparisonHistory {
            let anchorRefs = merged.map(\.sourceRefCanonical) + request.comparisonAnchorRefs
            for adapter in granted {
                absorb(try adapter.fetchSnapshots(anchorRefs: anchorRefs, window: windows.history, limit: Limits.channelFetchLimit))
            }
        }

        // 块预算：整快照纳入，直到 24 块（之后的快照计入截断）
        var chosen: [DiscoverySourceSnapshot] = []
        var usedBlocks = 0
        var matchedBlocks = 0
        for snapshot in merged {
            let outcome = DiscoveryEvidenceBuilder.segment(text: snapshot.text)
            matchedBlocks += outcome.blocks.count
            if usedBlocks + outcome.blocks.count <= Limits.totalBlocks {
                chosen.append(snapshot)
                usedBlocks += outcome.blocks.count
            }
        }

        let grantedDomains = granted.map(\.domain)
        let coverageInput = DiscoveryCoverageInput(
            domains: grantedDomains.sorted { $0.rawValue < $1.rawValue },
            windowStart: scanWindow.start,
            windowEnd: scanWindow.end,
            matchedBlockCount: matchedBlocks,
            truncatedBlockCount: matchedBlocks - usedBlocks,
            // 习惯域缺记录 ≠ 没做（F14）：含习惯域即分母未知
            denominatorKnown: !grantedDomains.contains(.habit),
            indexVersion: nil
        )
        let batch = builder.buildAtoms(
            from: chosen,
            coverageInput: coverageInput,
            accessRevision: Self.accessRevision(environment: environment),
            calendar: request.calendar,
            now: now
        )
        let blockAtoms = batch.atoms.filter { $0.sourceKind != .computedFact }
        let generationIDs = blockAtoms.prefix(Limits.generationBlocks).map(\.evidenceID)
        return DiscoveryMaterialPackage(
            supportAtoms: batch.atoms,
            generationEvidenceIDs: Array(generationIDs),
            coverage: batch.coverage,
            counterBudgetBlocks: max(0, Limits.totalBlocks - usedBlocks)
        )
    }

    // MARK: - 反例召回（§6）

    func counterRecall(
        candidate: DiscoveryCandidate,
        supportAtoms: [DiscoveryFactAtom],
        request: Request,
        environment: DiscoveryAccessSnapshot,
        now: Date
    ) throws -> DiscoveryCounterPackage {
        let granted = try grantedAdapters(environment: environment)
        let windows = Self.windows(for: request, now: now)
        let supportRefs = Set(supportAtoms.compactMap(\.localSourceRef).map(\.canonical))
        let supportBlockKeys = Set(supportAtoms
            .filter { $0.sourceKind != .computedFact }
            .map { Self.blockKey(sourceRef: $0.localSourceRef?.canonical ?? "", blockText: $0.sourceBlock) })

        // 1) 受限查询校验（≤3；越界整条拒绝并标检索不完整）
        var rejectedQueryCount = 0
        struct AcceptedQuery {
            let domains: [DiscoverySourceDomain]
            let keywords: [String]
            let anchorRefs: [String]
        }
        var accepted: [AcceptedQuery] = []
        for search in candidate.counterSearch.prefix(Limits.maxCounterQueriesPerCandidate) {
            // 域越界（schema 已限枚举，这里再与用户授权范围求交）
            let inScope = search.domains.allSatisfy { environment.settings.allowedDomains.contains($0) }
            // 关键词越界：文件路径/URL 等程序检索不支持的形态（§4：模型不能指定文件路径、URL）
            let keywordOutOfScope = search.keywords.contains { Self.isOutOfScopeKeyword($0) }
            guard inScope, !keywordOutOfScope else {
                rejectedQueryCount += 1
                continue
            }
            // anchorRefs 是 evidenceID：解析回支持材料来源（指向本批外 → 该锚无操作）
            let evidenceIDs = Set(search.anchorRefs)
            let anchorRefs = supportAtoms
                .filter { evidenceIDs.contains($0.evidenceID) }
                .compactMap(\.localSourceRef)
                .map(\.canonical)
            accepted.append(AcceptedQuery(domains: search.domains, keywords: search.keywords, anchorRefs: anchorRefs))
        }

        // 2) 执行接受的查询（时间由程序固定为全窗口，不接受模型自定时间）
        var pool: [DiscoverySourceSnapshot] = []
        var poolRefs = Set<String>()
        func absorb(_ snapshots: [DiscoverySourceSnapshot]) {
            for snapshot in snapshots where !poolRefs.contains(snapshot.sourceRefCanonical) {
                poolRefs.insert(snapshot.sourceRefCanonical)
                pool.append(snapshot)
            }
        }
        for query in accepted {
            for domain in query.domains {
                guard let adapter = granted.first(where: { $0.domain == domain }) else { continue }
                for keyword in query.keywords {
                    absorb(try adapter.fetchSnapshots(keyword: keyword, window: windows.history, limit: Limits.channelFetchLimit))
                }
                if !query.anchorRefs.isEmpty {
                    absorb(try adapter.fetchSnapshots(anchorRefs: query.anchorRefs, window: windows.history, limit: Limits.channelFetchLimit))
                }
            }
        }

        // 3) 程序侧中性回看（必须执行）：同对象/同主题全窗口扫描，
        //    防模型「证实自己」的关键词漏掉不相似的反例
        let neutralRefs = supportAtoms.flatMap(\.entityRefs) + Array(supportRefs)
        for adapter in granted {
            if !neutralRefs.isEmpty {
                absorb(try adapter.fetchSnapshots(topicRefs: neutralRefs, window: windows.history, limit: Limits.channelFetchLimit))
                absorb(try adapter.fetchSnapshots(anchorRefs: neutralRefs, window: windows.history, limit: Limits.channelFetchLimit))
            }
        }

        // 4) 成块、剔支持块、反例信号优先、≤6/候选
        let batch = DiscoveryEvidenceBuilder().buildAtoms(
            from: pool,
            coverageInput: DiscoveryCoverageInput(
                domains: granted.map(\.domain),
                windowStart: windows.history.start,
                windowEnd: windows.history.end,
                matchedBlockCount: 0,
                truncatedBlockCount: 0,
                denominatorKnown: !granted.map(\.domain).contains(.habit),
                indexVersion: nil
            ),
            accessRevision: Self.accessRevision(environment: environment),
            calendar: request.calendar,
            now: now,
            evidenceIDPrefix: "C"
        )
        let candidates = batch.atoms
            .filter { $0.sourceKind != .computedFact }
            .filter { atom in
                guard let ref = atom.localSourceRef else { return false }
                return !supportBlockKeys.contains(Self.blockKey(sourceRef: ref.canonical, blockText: atom.sourceBlock))
            }
            .sorted { lhs, rhs in
                let lhsSignal = Self.containsCounterSignal(lhs.sourceBlock)
                let rhsSignal = Self.containsCounterSignal(rhs.sourceBlock)
                if lhsSignal != rhsSignal { return lhsSignal }
                let lhsTime = lhs.occurredRange.start
                let rhsTime = rhs.occurredRange.start
                switch (lhsTime, rhsTime) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.evidenceID < rhs.evidenceID
                }
            }

        var state: DiscoveryCounterCoverageState
        if candidates.count > Limits.perCandidateCounterBlocks {
            state = .budgetTruncated
        } else if candidates.isEmpty {
            state = try historyState(granted: granted, window: windows.history)
        } else {
            state = .complete
        }

        return DiscoveryCounterPackage(
            blocks: Array(candidates.prefix(Limits.perCandidateCounterBlocks)),
            coverageState: state,
            rejectedQueryCount: rejectedQueryCount,
            neutralLookbackExecuted: true
        )
    }

    /// 三候选合并去重，仍受总包预算约束（§6）
    static func mergedCounterPackage(_ packages: [DiscoveryCounterPackage], totalBudget: Int) -> DiscoveryCounterPackage {
        var seen = Set<String>()
        var blocks: [DiscoveryFactAtom] = []
        var truncated = false
        for package in packages {
            for atom in package.blocks {
                guard let ref = atom.localSourceRef else { continue }
                let key = blockKey(sourceRef: ref.canonical, blockText: atom.sourceBlock)
                guard !seen.contains(key) else { continue }
                if blocks.count >= totalBudget {
                    truncated = true
                    break
                }
                seen.insert(key)
                blocks.append(atom)
            }
        }
        let state: DiscoveryCounterCoverageState
        if truncated || packages.contains(where: { $0.coverageState == .budgetTruncated }) {
            // 任一输入包已截断 → 合并覆盖不完整（截断不因合并而被洗掉）
            state = .budgetTruncated
        } else if packages.contains(where: { $0.coverageState == .insufficientHistoryOrIndex }) {
            state = .insufficientHistoryOrIndex
        } else if blocks.isEmpty {
            state = .completedNoHit
        } else {
            state = .complete
        }
        return DiscoveryCounterPackage(
            blocks: blocks,
            coverageState: state,
            rejectedQueryCount: packages.reduce(0) { $0 + $1.rejectedQueryCount },
            neutralLookbackExecuted: packages.allSatisfy(\.neutralLookbackExecuted)
        )
    }

    // MARK: - 回源核版本（变了不用旧块）

    /// 冻结 atom 回源重取：来源消失/不再可见（fetch 谓词含权限求交）或 sourceRevision
    /// 变化 → 失效。G4 发布前与 G6 提交前调用。
    func revalidate(
        atoms: [DiscoveryFactAtom],
        environment: DiscoveryAccessSnapshot,
        now: Date
    ) throws -> [DiscoveryStaleEvidence] {
        let granted = try grantedAdapters(environment: environment)
        var stale: [DiscoveryStaleEvidence] = []
        let atomByCanonical = Dictionary(
            atoms.compactMap { atom -> (String, DiscoveryFactAtom)? in
                atom.localSourceRef.map { ($0.canonical, atom) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let refsByKind = Dictionary(grouping: atomByCanonical.values.compactMap(\.localSourceRef)) { $0.kind }
        for adapter in granted {
            guard let refs = refsByKind[adapter.sourceKind], !refs.isEmpty else { continue }
            let snapshots = try adapter.fetchSnapshots(
                localIDs: refs.map(\.localID),
                limit: max(Limits.channelFetchLimit, refs.count)
            )
            let byCanonical = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceRefCanonical, $0) })
            for ref in refs {
                guard let atom = atomByCanonical[ref.canonical] else { continue }
                guard let current = byCanonical[ref.canonical] else {
                    stale.append(DiscoveryStaleEvidence(evidenceID: atom.evidenceID, sourceRef: ref.canonical, reason: .sourceMissing))
                    continue
                }
                if current.sourceRevision != atom.sourceRevision {
                    stale.append(DiscoveryStaleEvidence(evidenceID: atom.evidenceID, sourceRef: ref.canonical, reason: .revisionChanged))
                }
            }
        }
        return stale
    }

    // MARK: - 私有

    /// 授权域过滤（canReadSources 门控；被拒域不参与任何通道）
    private func grantedAdapters(environment: DiscoveryAccessSnapshot) throws -> [any DiscoverySourceAdapting] {
        adapters.filter { adapter in
            policy.canReadSources(domain: adapter.domain, environment: environment).isAllowed
        }
    }

    struct RetrievalWindows {
        /// 近 30 自然日 [start, end)
        let topic: DiscoveryTimeWindow
        /// 近 90 自然日 [start, end)
        let history: DiscoveryTimeWindow
    }

    /// 保存本次时区与确切区间（02 §3.2）：自然日按请求时区换算
    static func windows(for request: Request, now: Date) -> RetrievalWindows {
        let calendar = request.calendar
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let topicStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let historyStart = calendar.date(byAdding: .day, value: -89, to: todayStart) ?? todayStart
        return RetrievalWindows(
            topic: DiscoveryTimeWindow(start: topicStart, end: tomorrowStart),
            history: DiscoveryTimeWindow(start: historyStart, end: tomorrowStart)
        )
    }

    /// 空命中时的三态判定：窗口早于任何可读记录（或无记录/查询失败）→ 历史不足
    private func historyState(
        granted: [any DiscoverySourceAdapting],
        window: DiscoveryTimeWindow
    ) throws -> DiscoveryCounterCoverageState {
        for adapter in granted {
            let availability: DiscoverySourceAvailability
            do {
                availability = try adapter.availability()
            } catch {
                return .insufficientHistoryOrIndex
            }
            guard let earliest = availability.earliestRecordAt, earliest <= window.start else {
                return .insufficientHistoryOrIndex
            }
        }
        return .completedNoHit
    }

    /// 越界关键词：路径分隔符 / URL 前缀 / file 形态 / 家目录（§4）
    static func isOutOfScopeKeyword(_ keyword: String) -> Bool {
        let lowered = keyword.lowercased()
        if keyword.contains("/") || keyword.contains("\\") { return true }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        if lowered.hasPrefix("file:") || lowered.hasPrefix("~/") { return true }
        return false
    }

    static func containsCounterSignal(_ text: String) -> Bool {
        counterSignalLexicon.contains { text.contains($0) }
    }

    static func blockKey(sourceRef: String, blockText: String) -> String {
        sourceRef + "#" + DiscoveryContentDigest.sourceRevision(from: [blockText])
    }

    /// accessRevision（02 §2.2）：全局排除及发现范围的版本（授权代数 + 范围摘要）
    static func accessRevision(environment: DiscoveryAccessSnapshot) -> String {
        DiscoveryContentDigest.sourceRevision(from: [
            "discovery.access.v1",
            String(environment.settings.localGrantEpoch),
            DiscoveryScopeRevision.digest(domains: environment.settings.allowedDomains),
        ])
    }
}
