//
//  MatterPlanLaunchCard.swift
//  Holo
//
//  Matter V2 规划卡正式版（2026-09-21 方案 §3/§4.1）。
//
//  主层只有：标题、结果句、行动项、一个主 CTA。
//  - 「开始推进」= 确认整份计划：一次点击原子落库（HoloMatterPlanLaunchCoordinator）。
//  - 无重复候选不弹第二个确认表单；同名 active Matter 弹一次最小歧义。
//  - 冷启动回执经 origin link 重建（UseCase S4），不依赖临时 @State。
//  - 0 条可执行项不显示 CTA（纯建议回答）。
//
//  文案 verbatim 硬编码（翻译批处理统一收口），不进 xcstrings。
//

import SwiftUI

struct MatterPlanLaunchCard: View {
    let draft: HoloContextPlanDraft
    /// 方案卡消息 ID：launch 幂等来源键。
    let messageID: UUID
    var userMessageID: UUID? = nil
    var onOpenMatter: ((UUID) -> Void)? = nil
    /// 「调整计划」回调：把建议句交回对话输入框（nil 时隐藏入口）。
    var onAdjustPlan: (() -> Void)? = nil

    @State private var phase: Phase = .draftReady
    @State private var failureText: String?
    @State private var duplicateMatterID: UUID?
    @State private var restored = false
    /// R3：「因你的情况」展开态（effectID 或稳定索引键）。
    @State private var expandedEffectKeys: Set<String> = []

    private enum Phase: Equatable {
        case draftReady
        case launching
        case launched(LaunchSummary)
    }

    private struct LaunchSummary: Equatable {
        let matterID: UUID
        let stepCount: Int
        let nextActionTitle: String?

        init(matterID: UUID, stepCount: Int, nextActionTitle: String?) {
            self.matterID = matterID
            self.stepCount = stepCount
            self.nextActionTitle = nextActionTitle
        }

        init(receipt: HoloMatterPlanLaunchReceipt, nextActionTitle: String?) {
            self.matterID = receipt.matterID
            self.stepCount = receipt.taskIDs.count
            self.nextActionTitle = nextActionTitle
        }
    }

    /// 可执行条目（方案 §5.3：task / checklistItem 才产生任务）。
    private var actionableItems: [HoloContextPlanItem] {
        draft.items.filter { $0.kind == .task || $0.kind == .checklistItem }
    }

    /// R3：个人化影响（contextRefs 非空的 effect 才进「因你的情况」；无证据不展示）。
    private var personalEffects: [HoloContextPlanEffect] {
        (draft.planEffects ?? []).filter { !($0.contextRefs ?? []).isEmpty }
    }

    private var hasCTA: Bool { !actionableItems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .draftReady, .launching:
                readyContent
            case .launched(let summary):
                launchedContent(summary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: messageID) { restoreIfNeeded() }
        .alert(
            Text(verbatim: duplicateAlertTitle),
            isPresented: Binding(
                get: { duplicateMatterID != nil },
                set: { if !$0 { duplicateMatterID = nil } }
            )
        ) {
            Button {
                if let id = duplicateMatterID { onOpenMatter?(id) }
                duplicateMatterID = nil
            } label: {
                Text(verbatim: "打开已有计划")
            }
            Button {
                duplicateMatterID = nil
                startLaunch(existingMatterID: nil, forceUniqueTitle: true)
            } label: {
                Text(verbatim: "另建一个")
            }
            Button(role: .cancel) {} label: {
                Text(verbatim: "取消")
            }
        } message: {
            Text(verbatim: "继续它会沿用当前进度；另建会生成一个新的计划。")
        }
    }

    // MARK: - 计划态

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: draft.goalSummary)
                .font(.title3.weight(.semibold))
            Text(verbatim: draft.answerText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !personalEffects.isEmpty {
                personalEffectsSection
            }

            if hasCTA {
                Text(verbatim: "计划")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(actionableItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .strokeBorder(.quaternary, lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            Text(verbatim: item.title)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let failureText {
                Label {
                    Text(verbatim: failureText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if hasCTA {
                Button {
                    startLaunch(existingMatterID: nil, forceUniqueTitle: false)
                } label: {
                    Text(verbatim: phase == .launching ? "正在建立计划…" : (failureText == nil ? "开始推进" : "重试开始推进"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(phase == .launching)

                if let onAdjustPlan, failureText == nil, phase == .draftReady {
                    Button {
                        onAdjustPlan()
                    } label: {
                        Text(verbatim: "调整计划")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - 因你的情况（R3 主路径个性化差异）

    /// effect 图标（kind 白名单映射；旧 kind 归入 adjust/skip 视觉）。
    private func effectIcon(_ kind: String) -> String {
        switch kind {
        case "add": return "plus.circle"
        case "skip": return "minus.circle"
        case "choice": return "questionmark.circle"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var personalEffectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "因你的情况")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(Array(personalEffects.enumerated()), id: \.offset) { index, effect in
                let key = effect.effectID ?? "effect-\(index)"
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: effectIcon(effect.kind))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: effect.summary)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            if hasEffectExplanation(effect) {
                                Button {
                                    if expandedEffectKeys.contains(key) {
                                        expandedEffectKeys.remove(key)
                                    } else {
                                        expandedEffectKeys.insert(key)
                                    }
                                } label: {
                                    Label(
                                        expandedEffectKeys.contains(key) ? "收起" : "为什么",
                                        systemImage: expandedEffectKeys.contains(key) ? "chevron.up" : "chevron.down"
                                    )
                                    .font(.footnote)
                                }
                                .buttonStyle(.borderless)
                                if expandedEffectKeys.contains(key) {
                                    effectExplanation(effect)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func hasEffectExplanation(_ effect: HoloContextPlanEffect) -> Bool {
        let whyNow = effect.whyNow?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let delta = effect.personalizedDelta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !whyNow.isEmpty || !delta.isEmpty
    }

    private func effectExplanation(_ effect: HoloContextPlanEffect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let whyNow = effect.whyNow,
               !whyNow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: "为什么是现在：\(whyNow)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let delta = effect.personalizedDelta,
               !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: "和一般安排的差别：\(delta)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 已启动态（回执）

    private func launchedContent(_ summary: LaunchSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: "已开始推进「\(draft.goalSummary)」")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(verbatim: "已建立 \(summary.stepCount) 个步骤")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            if let next = summary.nextActionTitle {
                Text(verbatim: "下一步")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(verbatim: next)
                    .font(.body.weight(.medium))
            }

            Button {
                onOpenMatter?(summary.matterID)
            } label: {
                Text(verbatim: "打开计划")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - 启动

    private var duplicateAlertTitle: String {
        "你已有一个「\(draft.goalSummary)」"
    }

    /// 冷启动/重进对话：origin link 命中即恢复已启动态（不重执行、不依赖 @State）。
    private func restoreIfNeeded() {
        guard !restored, phase != .launching else { return }
        restored = true
        guard let summary = MatterPlanQuery.restoreLaunchSummary(
            contextPlanMessageID: messageID,
            repository: .shared
        ) else { return }
        phase = .launched(
            LaunchSummary(
                matterID: summary.matterID,
                stepCount: summary.stepCount,
                nextActionTitle: summary.nextAction?.title
            )
        )
    }

    @MainActor
    private func startLaunch(existingMatterID: UUID?, forceUniqueTitle: Bool) {
        var title = draft.goalSummary
        if forceUniqueTitle {
            title = Self.uniqueLaunchTitle(base: title, repository: .shared)
        }
        let request = HoloMatterPlanLaunchRequest(
            contextPlanMessageID: messageID,
            userMessageID: userMessageID,
            draft: draft,
            confirmedTitle: title,
            targetDate: nil,
            existingMatterID: existingMatterID
        )
        let preparation = HoloMatterPlanLaunchCoordinator.shared.prepare(request: request)
        switch preparation {
        case .alreadyLaunched:
            restoreIfNeeded()
        case .duplicateChoice(let matterID):
            guard existingMatterID == nil else { break }
            duplicateMatterID = matterID
        case .ready:
            launch(request: request)
        }
    }

    @MainActor
    private func launch(request: HoloMatterPlanLaunchRequest) {
        phase = .launching
        failureText = nil
        Task { @MainActor in
            do {
                let receipt = try await HoloMatterPlanLaunchCoordinator.shared.launch(request: request)
                let nextTitle = MatterPlanQuery
                    .nextActionTask(matterID: receipt.matterID, repository: .shared)?
                    .title
                phase = .launched(LaunchSummary(receipt: receipt, nextActionTitle: nextTitle))
            } catch {
                failureText = "这次没有建立成功，也没有创建部分内容。"
                phase = .draftReady
            }
        }
    }

    /// 「另建一个」的唯一标题：title 2、title 3…直到不与任何 active Matter 同名。
    @MainActor private static func uniqueLaunchTitle(base: String, repository: HoloMatterRepository) -> String {
        let activeTitles = Set(repository.matters(lifecycles: [.active]).map { $0.title })
        var candidate = base
        var suffix = 2
        while activeTitles.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// 孤儿回执卡：云异步规划的方案 JSON 未随信封落库（已知病，对账收治在途），
/// 但 Matter 已真实启动——按 origin link 恢复成功态，保住「打开计划」出口。
struct MatterPlanLaunchedReceiptCard: View {
    let matterID: UUID
    let matterTitle: String
    let stepCount: Int
    let nextActionTitle: String?
    var onOpenMatter: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: "已开始推进「\(matterTitle)」")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(verbatim: "已建立 \(stepCount) 个步骤")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            if let next = nextActionTitle {
                Text(verbatim: "下一步")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(verbatim: next)
                    .font(.body.weight(.medium))
            }

            Button {
                onOpenMatter?(matterID)
            } label: {
                Text(verbatim: "打开计划")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
