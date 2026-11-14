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
                        loadInputs: () async -> ([FinanceObservationInput], [ThoughtObservationInput]),
                        proposeClient: UnderstandingProposeClient) async -> ShadowRunReport {
        // ① 取数（真入口走 UnderstandingDataSource：授权门内；未授权→空，静默不跑）
        let (financeInputs, thoughtInputs) = await loadInputs()

        // ② 投影 + 索引（域全量替换=失效扇出）
        let storage = storage ?? storageDirectory()
        var index = ObservationIndex.load(directory: storage)
        _ = index.replaceDomain(.finance, with: FinanceObservationProjector.project(financeInputs))
        _ = index.replaceDomain(.thought, with: ThoughtObservationProjector.project(thoughtInputs))
        try? index.save(to: storage)
        let allObservations = index.observations.values.map { $0 }

        // ③ 主题 + 变化检测（首轮全为 added）
        let themes = ThemeIndex.buildThemes(from: allObservations)
        let lastThemes = loadThemeSnapshot(directory: storage)
        let changes = ThemeIndex.detectChanges(old: lastThemes, new: themes)
        saveThemeSnapshot(themes, directory: storage)

        // ④ 选主题：added 优先，其次 updated；上限 maxTopics
        let pending = changes
            .filter { $0.kind == .added || $0.kind == .updated }
            .sorted { ($0.kind == .added ? 0 : 1, $0.key) < ($1.kind == .added ? 0 : 1, $1.key) }
            .prefix(maxTopics)

        // ⑤ 逐主题全链
        var ledger = ShadowLedger.load(directory: storage)
        let router = EvidenceRouter(index: index)
        var outcomes: [String: Int] = [:]
        var rejections: [String] = []
        var modelFailures: [String] = []
        var proposalsReceived = 0
        let themesByKey = Dictionary(uniqueKeysWithValues: themes.map { ($0.key, $0) })
        let observationsByRef = Dictionary(uniqueKeysWithValues: allObservations.map { ($0.sourceRef, $0) })

        for change in pending {
            guard let theme = themesByKey[change.key] else { continue }
            let candidateID = "theme:\(theme.key):\(theme.fingerprint.prefix(8))"
            guard ledger.register(id: candidateID, themeKey: theme.key, now: now) != nil else { continue }
            _ = ledger.advance(id: candidateID, to: .packaged, now: now)
            _ = ledger.advance(id: candidateID, to: .proposing, now: now)

            // 提案（失败不重试：rejected 留诊断）。
            // 上送量上限（11-14 真机实锤 413：火锅/鞋类高频主题成员几十条全量上送
            // 撑爆请求体）——每主题最多 12 条代表性证据：按发生时间倒序取最新，
            // 保证覆盖多域（财务先行、想法/任务补位）。
            let evidence = Self.representativeEvidence(for: theme, in: index, now: now)
            let candidates: [ProposalCandidate]
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
            _ = ledger.advance(id: candidateID, to: .awaitingLocalEvidence, now: now)

            // 本机取证：归属查证（成员 refs）
            let memberRefs = theme.memberIDs.compactMap { index.observations[$0]?.sourceRef }
            let ownership = router.execute(EvidenceRequest(op: .checkOwnership, domain: .finance, sourceRefs: memberRefs))
            _ = ownership  // 影子期取证结果进评审包（M2.8 导出携带），不改变闸判定输入

            _ = ledger.advance(id: candidateID, to: .verifying, now: now)
            for candidate in candidates {
                let result = ProposalGate.evaluate(candidate: candidate, observations: Array(observationsByRef.values))
                let settled = ledger.settle(id: candidateID, gateResult: result, now: now)
                if let stage = settled?.stage {
                    outcomes[stage.rawValue, default: 0] += 1
                    if stage == .rejected, let reason = settled?.lastReason {
                        rejections.append("[\(theme.key)] \(reason)")
                    }
                }
                // 同主题多候选：首个终态已定，后续候选的闸判定计入结果分布（台账按主题单条，
                // 影子期以首个为准——多候选细分归 M3 评审迭代）。
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

    /// 代表性证据选取：≤12 条；跨域配额（财务≤8，其余域合计≥4 若有）+ 时间倒序。
    nonisolated static func representativeEvidence(for theme: ObservationTheme, in index: ObservationIndex, now: Date) -> [SemanticEvidenceItem] {
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
        return picked.map { obs in
            SemanticEvidenceItem(
                oid: obs.sourceRef,
                domain: obs.domain.rawValue,
                concepts: obs.concepts,
                attribution: obs.attribution.rawValue,
                businessState: obs.businessState.rawValue,
                window: obs.occurredAt.map { windowLabel(for: $0, now: now) } ?? "时间不可知",
                coverage: obs.coverage.map { "\($0.kind.rawValue):\($0.note)" },
                quoteExcerpt: obs.quote.map { String($0.prefix(50)) }
            )
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
