//
//  HoloMatterProjectionBuilder.swift
//  Holo
//
//  确定性状态与投影构建（方案 §11.6）
//
//  确定性部分先算：active confirmed Open Loop、全部等待判定、targetDate 处理窗口、
//  Next Action 排序。M1 版本 summary 为确定性模板；M2 起 AI 只在已验证事实内润色，
//  润色失败时本构建器的输出仍然完整可用（详情页不整页失败）。
//

import Foundation

nonisolated enum HoloMatterProjectionBuilder {

    /// 从 Repository 取数的轻量快照（避免 builder 直接依赖 managed object 上下文）。
    nonisolated struct MatterSnapshot: Sendable {
        let matterID: UUID
        let title: String
        let revision: Int64
        let targetDate: Date?
        let phase: HoloMatterPhase?

        init(matterID: UUID, title: String, revision: Int64, targetDate: Date?, phase: HoloMatterPhase?) {
            self.matterID = matterID
            self.title = title
            self.revision = revision
            self.targetDate = targetDate
            self.phase = phase
        }
    }

    /// 确定性构建投影。AI 增强由 ReconciliationCoordinator 在此基础上覆盖 summary/attentionReason。
    static func buildDeterministic(
        from snapshot: MatterSnapshot,
        loops: [HoloMatterAttentionPolicy.LoopInput],
        now: Date = Date()
    ) -> HoloMatterProjectionV1 {
        let attentionResult = HoloMatterAttentionPolicy.evaluate(targetDate: snapshot.targetDate, loops: loops, now: now)
        let nextAction = selectNextAction(loops: loops)

        return HoloMatterProjectionV1(
            matterID: snapshot.matterID,
            sourceMatterRevision: snapshot.revision,
            summary: deterministicSummary(snapshot: snapshot, loops: loops, attention: attentionResult.attention, now: now),
            attention: attentionResult.attention,
            attentionReason: attentionResult.reason,
            nextAction: nextAction,
            evidenceRefs: [],
            generatedAt: now
        )
    }

    /// Next Action 唯一排序规则（方案 §9.2：最多一个；无依据则为 nil，不填充泛泛建议）。
    /// - 只考虑已确认且未解决的问题；AI 建议（suggested）永不直接成为 Next Action。
    static func selectNextAction(loops: [HoloMatterAttentionPolicy.LoopInput], now: Date = Date()) -> HoloMatterNextAction? {
        // loop 输入不携带 ID（展示层补充）；排序依据：有日期且最近/已过期 > 优先级。
        let candidates = loops.filter { $0.epistemic == .confirmed && $0.state == .open }
        guard !candidates.isEmpty else { return nil }

        let top = candidates.min { lhs, rhs in
            let lDate = lhs.targetDate ?? .distantFuture
            let rDate = rhs.targetDate ?? .distantFuture
            if lDate != rDate { return lDate < rDate }
            return lhs.title < rhs.title
        }
        guard let top else { return nil }

        let reason: String
        if let deadline = top.targetDate {
            if deadline < now {
                reason = String(localized: "期限已过，需要立即处理")
            } else {
                reason = String(localized: "距离期限最近，且还没有解决")
            }
        } else {
            reason = String(localized: "其余事项都在等待或依赖它")
        }

        return HoloMatterNextAction(
            kind: .openLoopAction,
            entityID: nil,
            title: top.title,
            reason: reason,
            targetDate: top.targetDate,
            evidenceRefs: []
        )
    }

    /// 确定性 summary 模板（M2 起 AI 在同一事实集合内润色，失败即回退本输出）。
    static func deterministicSummary(
        snapshot: MatterSnapshot,
        loops: [HoloMatterAttentionPolicy.LoopInput],
        attention: HoloMatterAttention,
        now: Date
    ) -> String {
        let open = loops.filter { $0.state == .open }
        let waiting = loops.filter { $0.state == .waiting }
        let confirmedOpen = open.filter { $0.epistemic == .confirmed }
        let suggestedOpen = open.filter { $0.epistemic == .suggested }

        var parts: [String] = []
        switch attention {
        case .atRisk:
            parts.append(String(localized: "有事项已经过期"))
        case .needsAttention:
            parts.append(String(localized: "有事项临近处理窗口"))
        case .waiting:
            parts.append(String(localized: "关键事项都在等待外部结果"))
        case .onTrack:
            parts.append(String(localized: "整体在正常推进"))
        case .unknown:
            parts.append(String(localized: "还在收集信息"))
        }

        if !confirmedOpen.isEmpty {
            parts.append(String(localized: "还有 \(confirmedOpen.count) 个已确认的问题未解决"))
        }
        if !suggestedOpen.isEmpty {
            parts.append(String(localized: "另有 \(suggestedOpen.count) 个建议待你确认"))
        }
        if !waiting.isEmpty {
            parts.append(String(localized: "\(waiting.count) 项在等待外部结果"))
        }
        if parts.count == 1 {
            parts.append(String(localized: "暂无待处理问题"))
        }

        return parts.joined(separator: "；") + "。"
    }
}
