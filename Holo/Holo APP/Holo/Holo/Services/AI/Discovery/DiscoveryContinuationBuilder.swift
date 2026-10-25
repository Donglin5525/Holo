//
//  DiscoveryContinuationBuilder.swift
//  Holo
//
//  「一个发现」续聊草稿（实施包 01 §3「聊聊这个」/ 02 §1 DiscoveryContinuationBuilder）。
//
//  · 草稿 = 发现标题 + 正文摘要 + 来源范围描述 + 一句建议问句；
//    不替用户下结论、不自动发送（发送动作归聊天输入路径）。
//  · 发送前来源重核（检查位 6，03 §5）：validateForSend 重新取当前原文——
//    撤源/改版/过期/否定后返回 false，UI 显示「来源已不可用」；
//    不把旧摘录永久写入通用对话背景（撤源后旧引用只保留「来源已不可用」提示）。
//
//  来源重核实现：读取该 run 的 BoundedRetrievalIndex（evidenceID → sourceRef/版本），
//  按 kind 路由适配器回源重取，比对 sourceRevision；任一来源消失或版本变化即 false。
//  纯本地操作，不发网络。
//

import Foundation

// MARK: - 续聊构建器

@MainActor
final class DiscoveryContinuationBuilder {

    private let store: DiscoveryStore
    private let settings: DiscoverySettings
    private let accessPolicy: DiscoveryAccessPolicy
    private let adapters: [any DiscoverySourceAdapting]
    private let clock: () -> Date
    private let consentProvider: () -> Bool

    init(
        store: DiscoveryStore,
        settings: DiscoverySettings,
        accessPolicy: DiscoveryAccessPolicy = DiscoveryAccessPolicy(),
        adapters: [any DiscoverySourceAdapting],
        clock: @escaping () -> Date = { Date() },
        consentProvider: @escaping () -> Bool = { HoloAIDataProcessingConsent.shared.isGranted }
    ) {
        self.store = store
        self.settings = settings
        self.accessPolicy = accessPolicy
        self.adapters = adapters
        self.clock = clock
        self.consentProvider = consentProvider
    }

    // MARK: - 草稿组装

    /// 从当前有效发现构建可编辑草稿。发现上下文最小化（02 续聊约束）：
    /// 标题 + 正文摘要 + 来源范围；不携带完整历史发现正文或用户反馈内容。
    func buildDraft(
        from presentation: DiscoveryFindingPresentation,
        allowedDomains: Set<DiscoverySourceDomain>
    ) -> DiscoveryConversationDraft {
        DiscoveryConversationDraft(
            findingTitle: presentation.title,
            findingSummary: presentation.body.joined(separator: ""),
            sourceScopeDescription: Self.sourceScopeDescription(domains: allowedDomains),
            suggestedDraftText: Self.suggestedDraftText(title: presentation.title),
            findingID: presentation.findingID
        )
    }

    /// 来源范围中文描述（用户勾选的 allowedDomains；01 §5：UI 必须显示对象与来源范围）。
    static func sourceScopeDescription(domains: Set<DiscoverySourceDomain>) -> String {
        let names: [DiscoverySourceDomain: String] = [
            .thought: "想法",
            .task: "任务",
            .habit: "习惯记录",
        ]
        let ordered = DiscoverySourceDomain.allCases
            .filter { domains.contains($0) }
            .compactMap { names[$0] }
        guard !ordered.isEmpty else { return "未选择来源范围" }
        return "基于你允许的「\(ordered.joined(separator: "、"))」记录（近 90 天内已保存的内容）"
    }

    /// 一句围绕发现的开放问句：不下结论、不建议行动、不自动发送。
    static func suggestedDraftText(title: String) -> String {
        "关于「\(title)」这个观察，你怎么看？可以结合它引用的记录再聊聊。"
    }

    // MARK: - 发送前来源重核（检查位 6）

    /// 聊天发送路径在真正发出前调用：发现仍有效（总授权/开关/TTL/未否定）且
    /// 依赖来源回源重取未变。false 时 UI 显示「来源已不可用」，不继续注入该来源包。
    func validateForSend(findingID: String) async -> Bool {
        let now = clock()
        guard let record = (try? store.activeFinding(now: now)), record.id.uuidString == findingID else {
            return false
        }
        let environment = DiscoveryAccessSnapshot(
            now: now,
            isGlobalConsentGranted: consentProvider(),
            settings: settings.snapshot(),
            serverControlRevision: (try? store.latestControlSnapshot())??.revision,
            dailyAutoBatchBudgetRemaining: 1
        )
        let negated = (try? store.hasNegativeFeedback(fingerprintMaterial: record.payload.fingerprintMaterial)) ?? false
        let displayState = DiscoveryFindingDisplayState(
            status: record.status,
            expiresAt: record.expiresAt,
            subjectNegativeFeedbackHit: negated,
            dependenciesValid: true   // 具体依赖有效性由下面的回源重核给出
        )
        guard accessPolicy.canContinueConversation(finding: displayState, environment: environment).isAllowed else {
            return false
        }
        // 回源重核：该发现的依赖来源（支持/反例/基线）全部仍可取且版本未变
        return (try? revalidateFindingSources(runID: record.runID)) ?? false
    }

    /// 回源重核：BoundedRetrievalIndex 的全部条目按 kind 路由适配器重取并比对版本。
    /// 任一来源消失或 sourceRevision 变化 → false（撤源后旧摘录不再可用）。
    private func revalidateFindingSources(runID: String) throws -> Bool {
        let entries = try store.retrievalIndex(runID: runID)
        guard !entries.isEmpty else { return false }   // 索引已清理（关闭/批次清理）→ 来源不可用

        let byKind = Dictionary(grouping: entries) { $0.kind }
        for adapter in adapters {
            guard let kindEntries = byKind[adapter.sourceKind], !kindEntries.isEmpty else { continue }
            let localIDs = kindEntries.map(\.sourceRef)
                .filter { $0.hasPrefix("\(adapter.sourceKind.rawValue):") }
                .map { String($0.dropFirst(adapter.sourceKind.rawValue.count + 1)) }
            guard !localIDs.isEmpty else { continue }
            let snapshots = try adapter.fetchSnapshots(localIDs: localIDs, limit: localIDs.count)
            let byCanonical = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceRefCanonical, $0) })
            for entry in kindEntries {
                guard let current = byCanonical[entry.sourceRef] else { return false }   // 来源消失/不再可见
                if current.sourceRevision != entry.sourceRevision { return false }       // 参与字段已变化
            }
        }
        return true
    }
}
