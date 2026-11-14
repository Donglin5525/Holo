//
//  UnderstandingShadowRunner.swift
//  Holo
//
//  理解引擎 M2 真数据影子运行：全链编排（数据源→投影→索引→主题→提案→取证→核验→影子台账）。
//
//  影子铁律：只读真数据；产出只进本地影子台账；失败不重试（11-09 教训）；
//  单轮主题上限（预算：每主题恰好 1 次模型调用）。
//

import Foundation

// MARK: - 提案客户端协议（真客户端走 understanding_proposal；测试注入 fixture）

nonisolated struct SemanticEvidenceItem: Codable, Equatable, Sendable {
    var oid: String
    var domain: String
    var concepts: [String]
    var attribution: String
    var businessState: String
    var window: String
    var coverage: String?
    /// 想法原句截断（≤50 字，仅授权门内上送；工程稿 §5.2「必要原句按需截取」）。
    var quoteExcerpt: String?
}

nonisolated protocol UnderstandingProposeClient: Sendable {
    func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate]
}

// MARK: - 影子运行报告

nonisolated struct ShadowRunReport: Codable, Equatable, Sendable {
    var ranAt: Date
    var financeObservations: Int
    var thoughtObservations: Int
    var habitObservations: Int
    var themesTotal: Int
    var topicsProcessed: Int
    var proposalsReceived: Int
    var outcomes: [String: Int]     // 终态 → 数
    var rejections: [String]        // 拒绝理由（评审可追溯）
    var modelFailures: [String]     // 提案失败主题（不重试，留诊断）
}

// MARK: - 编排器

@MainActor
enum UnderstandingShadowRunner {

    /// 影子数据目录（索引/台账/主题快照；本机可重建，不进 CloudKit）。
    static func storageDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnderstandingShadow", isDirectory: true)
    }

    /// 单轮影子运行。maxTopics=3 对应预算上限（每主题 1 次提案调用）。
    /// loadInputs/proposeClient/storage 均为注入点：真入口传真件（见 UnderstandingRealEntry），
    /// standalone 测试传 fixture——Runner 本体零 App 依赖。
    static func runOnce(now: Date = Date(),
                        maxTopics: Int = 3,
                        storage: URL? = nil,
                        loadInputs: () async -> ([FinanceObservationInput], [ThoughtObservationInput], [HabitObservationInput]),
                        proposeClient: UnderstandingProposeClient) async -> ShadowRunReport {
        // ① 取数（真入口走 UnderstandingDataSource：授权门内；未授权→空，静默不跑）
        let (financeInputs, thoughtInputs, habitInputs) = await loadInputs()

        // ② 投影 + 索引（域全量替换=失效扇出）
        let storage = storage ?? storageDirectory()
        var index = ObservationIndex.load(directory: storage)
        _ = index.replaceDomain(.finance, with: FinanceObservationProjector.project(financeInputs))
        _ = index.replaceDomain(.thought, with: ThoughtObservationProjector.project(thoughtInputs))
        _ = index.replaceDomain(.habit, with: HabitObservationProjector.project(habitInputs))
        try? index.save(to: storage)
        let allObservations = index.observations.values.map { $0 }

        // ③ 主题 + 变化检测（首轮全为 added）
        let themes = ThemeIndex.buildThemes(from: allObservations)
        let lastThemes = loadThemeSnapshot(directory: storage)
        let changes = ThemeIndex.detectChanges(old: lastThemes, new: themes)
        saveThemeSnapshot(themes, directory: storage)

        // ④ 选主题（2026-11-14 对抗轮 BUG-2 修复）：
        // a) added/updated 优先；b) 从未登记过的主题（首轮未入选）次之——否则
        //    首轮落选主题永远 unchanged，永久饥饿；c) 排序按成员数降序——字典序
        //    会让 ASCII key（AppStore/GPT）系统性挤占 CJK 主题（BUG-3）。
        let ledgerForSelection = ShadowLedger.load(directory: storage)
        let processedKeys = Set(ledgerForSelection.candidates.values.map(\.themeKey))
        let themesByKey = Dictionary(uniqueKeysWithValues: themes.map { ($0.key, $0) })
        var pendingKeys = changes.filter { $0.kind == .added || $0.kind == .updated }.map(\.key)
        let neverProcessed = themes
            .filter { !processedKeys.contains($0.key) && !pendingKeys.contains($0.key) }
            .map(\.key)
        pendingKeys += neverProcessed
        let pending = pendingKeys
            .compactMap { themesByKey[$0] }
            // 语义丰富度门槛（2026-11-14 用户旅程画像1实锤）：纯类目聚合主题
            //（轻度记账用户 90% 无备注时的「餐饮」巨主题）等价 legacy 统计形状，
            // 模型只能产出计数式废话（M1.2 定谳），且成员最多永远第一个被处理——
            // 第一笔模型费全买废话。跳过提案，留在索引等语义线索出现。
            .filter { Self.hasSemanticValue($0, index: index) }
            .sorted { ($0.memberIDs.count, $0.key) > ($1.memberIDs.count, $1.key) }
            .prefix(maxTopics)

        // ⑤ 逐主题全链
        var ledger = ShadowLedger.load(directory: storage)
        let router = EvidenceRouter(index: index)
        var outcomes: [String: Int] = [:]
        var rejections: [String] = []
        var modelFailures: [String] = []
        var proposalsReceived = 0
        let observationsByRef = Dictionary(uniqueKeysWithValues: allObservations.map { ($0.sourceRef, $0) })

        for theme in pending {
            let candidateID = "theme:\(theme.key):\(theme.fingerprint.prefix(8))"
            guard ledger.register(id: candidateID, themeKey: theme.key, now: now) != nil else { continue }
            // 数据驱动失效（BUG-5）：同主题旧版本终态条目撤下，评审只看当前版本。
            _ = ledger.markSuperseded(themeKey: theme.key, excluding: candidateID, now: now)
            _ = ledger.advance(id: candidateID, to: .packaged, now: now)
            _ = ledger.advance(id: candidateID, to: .proposing, now: now)

            // 提案分流（2026-11-15 拍板第三件事）：habit 域纯主题（habit 成员过半）
            // 走确定性提案器——用户自证类阶段命题程序直出，不烧模型；混域主题
            // 仍走模型通道（可能有跨域价值）。两条通道共用同一套闸。
            let memberObservations = theme.memberIDs.compactMap { index.observations[$0] }
            let habitCount = memberObservations.filter { $0.domain == .habit }.count
            let useDeterministic = habitCount > 0 && habitCount * 2 >= theme.memberIDs.count

            let candidates: [ProposalCandidate]
            let refByShortID: [String: String]
            if useDeterministic {
                refByShortID = [:]   // 直出 refs 即真实 sourceRef，无短编号映射需求
                candidates = HabitPhaseProposer().propose(themeKey: theme.key, members: memberObservations, now: now)
                proposalsReceived += candidates.count
            } else {
                // 上送量上限（11-14 真机实锤 413：火锅/鞋类高频主题成员几十条全量上送
                // 撑爆请求体）——每主题最多 12 条代表性证据：按发生时间倒序取最新，
                // 保证覆盖多域（财务先行、想法/任务补位）。
                // 短编号证据（BUG-6 真数据实锤：给模型 36 位 UUID 抄写错一个字符即整条
                // 报废——3/6 提案损耗；方案本设计即短 oid。映射表供 gate 判定前回源。
                let (evidence, mapping) = Self.representativeEvidence(for: theme, in: index, now: now)
                refByShortID = mapping
                // 提案（失败不重试：rejected 留诊断）。
                do {
                    candidates = try await proposeClient.propose(themeKey: theme.key, evidence: evidence)
                    proposalsReceived += candidates.count
                } catch {
                    _ = ledger.advance(id: candidateID, to: .rejected, now: now,
                                       reason: "提案调用失败（不重试）:\(String(describing: error).prefix(80))")
                    let errorText = String(describing: error)
                    modelFailures.append(theme.key + "｜" + errorText.prefix(200))
                    outcomes["rejected", default: 0] += 1
                    continue
                }
            }
            _ = ledger.advance(id: candidateID, to: .awaitingLocalEvidence, now: now)

            // 本机取证：归属查证（成员 refs）
            let memberRefs = theme.memberIDs.compactMap { index.observations[$0]?.sourceRef }
            let ownership = router.execute(EvidenceRequest(op: .checkOwnership, domain: .finance, sourceRefs: memberRefs))
            _ = ownership  // 影子期取证结果进评审包（M2.8 导出携带），不改变闸判定输入

            _ = ledger.advance(id: candidateID, to: .verifying, now: now)
            // 多候选（2026-11-14 对抗轮 BUG-1 修复）：每条候选独立登记一条台账
            // （id 加候选序号后缀），第 1 条进终态不再吞掉第 2 条的判定。
            // 主条目（无后缀）承载主题级流转；候选条目只经 register→settle 直达终态。
            for (candidateIndex, candidate) in candidates.enumerated() {
                // BUG-6：supportingRefs 短编号回源（e3→真实sourceRef）；UUID 原样保留。
                var resolved = candidate
                resolved.supportingRefs = candidate.supportingRefs.map { ref in
                    refByShortID[ref] ?? ref
                }
                let result = ProposalGate.evaluate(candidate: resolved, observations: Array(observationsByRef.values))
                // 认识三标记（方案 §4.2，2026-11-15）：从回源后的引用证据推导，
                // 随终态落台账——M3 上岗注入按 usage 放行、按 validity 过期。
                let cited = resolved.supportingRefs.compactMap { observationsByRef[$0] }
                let provenance = EpistemicTags.provenance(cited: cited)
                let validity = EpistemicTags.validity(kind: resolved.kind)
                var settled = ledger.settle(id: candidateID, gateResult: result,
                                            provenance: provenance, validity: validity, now: now)
                if candidateIndex > 0 {
                    let subID = candidateID + "#c\(candidateIndex + 1)"
                    if ledger.register(id: subID, themeKey: theme.key, now: now) != nil {
                        _ = ledger.advance(id: subID, to: .packaged, now: now)
                        _ = ledger.advance(id: subID, to: .proposing, now: now)
                        _ = ledger.advance(id: subID, to: .awaitingLocalEvidence, now: now)
                        _ = ledger.advance(id: subID, to: .verifying, now: now)
                        settled = ledger.settle(id: subID, gateResult: result,
                                                provenance: provenance, validity: validity, now: now)
                    }
                }
                if let stage = settled?.stage {
                    outcomes[stage.rawValue, default: 0] += 1
                    if stage == .rejected, let reason = settled?.lastReason {
                        rejections.append("[\(theme.key)] \(reason)")
                    }
                }
            }
            if candidates.isEmpty {
                _ = ledger.settle(id: candidateID, gateResult: (true, "observe", []), now: now)
                outcomes["observing", default: 0] += 1
            }
        }

        try? ledger.save(to: storage)
        return ShadowRunReport(
            ranAt: now,
            financeObservations: financeInputs.count,
            thoughtObservations: thoughtInputs.count,
            habitObservations: habitInputs.count,
            themesTotal: themes.count,
            topicsProcessed: pending.count,
            proposalsReceived: proposalsReceived,
            outcomes: outcomes,
            rejections: rejections,
            modelFailures: modelFailures
        )
    }

    /// 主题快照持久化（变化检测的旧值来源）。
    static func loadThemeSnapshot(directory: URL) -> [ObservationTheme] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("themes.json")),
              let themes = try? JSONDecoder().decode([ObservationTheme].self, from: data) else { return [] }
        return themes
    }

    static func saveThemeSnapshot(_ themes: [ObservationTheme], directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(themes) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("themes.json"), options: .atomic)
        }
    }

    /// 主题语义价值判定：任一成员带非空备注（quote）或有想法域成员 → true；
    /// 纯类目聚合（全部无备注、纯财务类目名概念）→ false（不配调模型）。
    nonisolated static func hasSemanticValue(_ theme: ObservationTheme, index: ObservationIndex) -> Bool {
        for id in theme.memberIDs {
            guard let obs = index.observations[id] else { continue }
            if obs.domain == .thought { return true }
            // habit 域豁免：习惯名是用户自建语义实体（非系统类目聚合），
            // 打卡无备注是常态（0.7% 才带备注）——不算「纯类目废话」。
            if obs.domain == .habit { return true }
            if let quote = obs.quote, !quote.isEmpty { return true }
        }
        return false
    }

    /// 代表性证据选取：≤12 条；跨域配额（财务≤8，其余域合计≥4 若有）+ 时间倒序。
    /// 返回 (短编号证据项, 短编号→真实sourceRef 映射)。
    nonisolated static func representativeEvidence(for theme: ObservationTheme, in index: ObservationIndex, now: Date) -> ([SemanticEvidenceItem], [String: String]) {
        let members = theme.memberIDs.compactMap { index.observations[$0] }
        let sorted = members.sorted { ($0.occurredAt ?? $0.recordedAt) > ($1.occurredAt ?? $1.recordedAt) }
        var picked: [LifeObservation] = []
        var financeCount = 0
        for obs in sorted {
            if picked.count >= 12 { break }
            if obs.domain == .finance {
                if financeCount >= 8 { continue }
                financeCount += 1
            }
            picked.append(obs)
        }
        // oid 用短编号（BUG-6）：模型抄 e1..e12 不会错；真实 sourceRef 随返回值
        // 交给调用方做 gate 回源（修复自映射陷阱：value 不能取 evidence.oid 本身）。
        let shortToSourceRef = Dictionary(
            uniqueKeysWithValues: picked.enumerated().map { ("e\($0.offset + 1)", $0.element.sourceRef) }
        )
        let items = picked.enumerated().map { index, obs in
            SemanticEvidenceItem(
                oid: "e\(index + 1)",
                domain: obs.domain.rawValue,
                concepts: obs.concepts,
                attribution: obs.attribution.rawValue,
                businessState: obs.businessState.rawValue,
                window: obs.occurredAt.map { windowLabel(for: $0, now: now) } ?? "时间不可知",
                coverage: obs.coverage.map { "\($0.kind.rawValue):\($0.note)" },
                quoteExcerpt: obs.quote.map { String($0.prefix(50)) }
            )
        }
        return (items, shortToSourceRef)
    }

    /// 时段带（BUG-7）：补账默认午夜 → unknown；按本地时段四分。
    nonisolated static func timeOfDayBand(of obs: LifeObservation) -> String {
        if obs.timePrecision == .midnightDefault { return "unknown" }
        guard let at = obs.occurredAt else { return "unknown" }
        let hour = Calendar.current.component(.hour, from: at)
        switch hour {
        case 5..<11: return "morning"
        case 11..<17: return "afternoon"
        case 17..<23: return "evening"
        default: return "night"
        }
    }

    nonisolated static func windowLabel(for date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days <= 1 { return "近1-2天" }
        if days <= 7 { return "近1周" }
        if days <= 31 { return "近1个月" }
        if days <= 92 { return "近3个月" }
        return "3个月以上"
    }
}
