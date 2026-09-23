//
//  ContextPlanChatCard.swift
//  Holo
//
//  通用个人情境方案草案卡（实施方案 §10）。
//
//  - 展示 answerText、可勾选条目（含依据徽标与相对时间）、未知问题、覆盖说明。
//  - 「查看依据」只展开实际采用的情境命题（推断类带限定表达）。
//  - 保存走 HoloContextPlanExecutionAdapter（幂等+对账），只创建选中项。
//  - 旧草案保存后用户改计划：实质变化的事项重新确认，未变项复用不重复创建。
//

import SwiftUI

struct ContextPlanChatCard: View {
    /// 消息里的草案 JSON（HoloContextPlanDraft，iso8601）。
    let draftJSON: String?
    /// 本条方案卡消息 ID（Matter 激活的幂等来源键）。
    var messageID: UUID = UUID()
    /// 关联的用户消息 ID（可空；用于 Matter 关联对话上下文）。
    var userMessageID: UUID? = nil
    /// 保存回执存储（V2 带任务 ID；legacy 指纹兜底）。
    let receipts: ContextPlanReceiptStoring
    /// 任务创建出口（逐条回报真实回执；写入成功才算成功）。
    /// 闭包内负责归清单与创建后即时补链；卡片只消费回执。
    let onCreateTasks: ([HoloContextPlanTaskCreation]) -> [String: HoloContextPlanCreationReceipt]
    /// 判断任务是否仍存在（回执降级判定用：任务被删后不再显示「已加入」）。
    var taskExists: ((UUID) -> Bool)? = nil
    /// 任务详情出口（已加入态「查看」；nil 时仅显示状态）。
    var onOpenTask: ((UUID) -> Void)? = nil
    /// Matter「查看」出口（打开事情详情；nil 时仅显示状态）。
    var onOpenMatter: ((UUID) -> Void)? = nil

    @State private var draft0: HoloContextPlanDraft?
    /// 每个条目自己的保存状态（§8.1：单项状态机，互不影响）。
    @State private var itemSaveStates: [String: HoloContextPlanItemSaveState] = [:]
    @State private var confirmedDates: [String: Date] = [:]
    @State private var showBasis = false
    /// 批量「全部加入」的次要快捷操作结果。
    @State private var batchState: BatchState = .idle
    @State private var duplicates: [String] = []
    /// 证据回源失败（原记录已删除/域不可达）的统一交代（§7.2：不跳空页面）。
    @State private var showEvidenceUnavailable = false
    // §10 纠正三选项：「已安排好/本次不用」收起本次草案；「情况变了」走 followUp 重生成。
    @State private var resolvedState: ResolvedState = .active
    @State private var followUpText = ""
    @State private var regenerating = false

    // MARK: Matter 激活（方案 §13.1）

    @State private var matterPreparation: HoloMatterActivationCoordinator.Preparation?
    @State private var showActivationSheet = false
    @State private var activationTitle = ""
    @State private var activationTargetDate: Date?
    @State private var activationExistingMatterID: UUID?
    @State private var activationInFlight = false
    @State private var activationErrorText: String?

    /// 批量快捷操作结果（次要入口；单项主入口状态在 itemSaveStates）。
    enum BatchState: Equatable {
        case idle
        case saved(Int)
        case savedWithFailures(succeeded: Int, failed: Int)
        case failed
        case blocked
    }

    enum ResolvedState: String, Equatable {
        case active
        case arranged
        case declined
    }

    var body: some View {
        Group {
            if let draft = draft0, HoloMatterRolloutPolicy.unifiedLaunchV2Enabled {
                // V2 统一启动（2026-09-21 战略收敛）：单 CTA 原子落库；旧交互经开关回退。
                MatterPlanLaunchCard(
                    draft: draft,
                    messageID: messageID,
                    userMessageID: userMessageID,
                    onOpenMatter: onOpenMatter
                )
            } else {
                legacyBody
            }
        }
        .onAppear { loadDraft() }
        .alert(
            String(localized: "原记录已删除或当前不可访问"),
            isPresented: $showEvidenceUnavailable
        ) {
            Button(String(localized: "知道了"), role: .cancel) {}
        } message: {
            Text(String(localized: "这条记录可能已被删除，或当前版本无法打开它。"))
        }
    }

    /// 旧卡片布局（V2 开关关闭时的回退路径；内部试用结束后的下一版本退役）。
    private var legacyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = draft0 {
                header(draft)
                answer(draft)
                planEffectsSection(draft)
                itemsSection(draft)
                unknownsSection(draft)
                if showBasis {
                    basisSection(draft)
                }
                if resolvedState == .active {
                    saveSection(draft)
                    correctionSection(draft)
                    matterActivationSection(draft)
                } else {
                    resolvedLabel
                }
            } else {
                Text(String(localized: "方案草案已失效，可以重新提问生成。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 区块

    private func header(_ draft: HoloContextPlanDraft) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "map")
                .font(.caption)
                .foregroundStyle(.tint)
            Text(String(localized: "结合你的情况整理的方案"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showBasis.toggle()
            } label: {
                Label(
                    String(localized: "查看依据"),
                    systemImage: showBasis ? "chevron.up" : "chevron.down"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private func answer(_ draft: HoloContextPlanDraft) -> some View {
        Text(draft.answerText)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「因你的情况调整了」区块（P0 §4.6）：只展示带个人依据的变化；
    /// 没有个人依据变化时整个区块不出现，不给一般建议贴个性化标签。
    @ViewBuilder
    private func planEffectsSection(_ draft: HoloContextPlanDraft) -> some View {
        let personal = (draft.planEffects ?? []).filter { !($0.contextRefs ?? []).isEmpty }
        if !personal.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "因你的情况调整了"), systemImage: "arrow.up.arrow.down.square")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                ForEach(Array(personal.enumerated()), id: \.offset) { _, effect in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: effectIcon(effect.kind))
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        Text(effect.summary)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func effectIcon(_ kind: String) -> String {
        switch kind {
        case "add": return "plus.circle"
        case "remove": return "minus.circle"
        case "reorder": return "arrow.up.arrow.down"
        case "reschedule": return "clock.arrow.circlepath"
        case "choice": return "arrow.triangle.branch"
        default: return "circle"
        }
    }

    private func itemsSection(_ draft: HoloContextPlanDraft) -> some View {
        Group {
            if !draft.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.items) { item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: HoloContextPlanItem) -> some View {
        let isTask = item.kind == .task || item.kind == .checklistItem
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: item.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                    basisBadge(item.basis)
                }
                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let timing = item.relativeTiming {
                    Label(timing, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isTask {
                    // 日期三态（§8.1 规则 8）：未设置就显示「设置日期」，绝不默认今天；
                    // 建议值只进选择器，用户确认后 confirmedDates 才有值、保存才带日期。
                    if confirmedDates[item.itemID] != nil {
                        HStack(spacing: 8) {
                            DatePicker(
                                String(localized: "日期"),
                                selection: Binding(
                                    get: { confirmedDates[item.itemID] ?? Date() },
                                    set: { confirmedDates[item.itemID] = $0 }
                                ),
                                displayedComponents: .date
                            )
                            .font(.caption2)
                            Button {
                                confirmedDates[item.itemID] = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("移除日期"))
                        }
                    } else {
                        Button {
                            confirmedDates[item.itemID] = Date()
                        } label: {
                            Label(String(localized: "设置日期"), systemImage: "calendar.badge.plus")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    // 单项即时加入（§8.1）：主入口在条目行内，逐条真实回执。
                    itemSaveControl(item)
                }
            }
        }
    }

    /// 单条任务的保存状态控件（§8.1 交互状态表）。
    @ViewBuilder
    private func itemSaveControl(_ item: HoloContextPlanItem) -> some View {
        let state = itemSaveStates[item.itemID] ?? .idle
        switch state {
        case .idle:
            Button {
                performSingleSave(item)
            } label: {
                Label(String(localized: "加入待办"), systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        case .saving:
            ProgressView()
                .controlSize(.mini)
        case .added(let taskID):
            HStack(spacing: 8) {
                Label(String(localized: "已加入"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button {
                    onOpenTask?(taskID)
                } label: {
                    Text(String(localized: "查看"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }
        case .addedLegacy:
            Label(String(localized: "已加入"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .taskDeleted:
            HStack(spacing: 8) {
                Label(String(localized: "原任务已删除"), systemImage: "trash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    performSingleSave(item, force: true)
                } label: {
                    Text(String(localized: "重新加入"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        case .failed:
            HStack(spacing: 8) {
                Label(String(localized: "未加入成功"), systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button {
                    performSingleSave(item)
                } label: {
                    Text(String(localized: "重试"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        case .blocked:
            Label(String(localized: "方案背景已变化，请重新生成"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func unknownsSection(_ draft: HoloContextPlanDraft) -> some View {
        Group {
            if !draft.unknowns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "这些情况会影响安排"), systemImage: "questionmark.circle")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(draft.unknowns.enumerated()), id: \.offset) { _, unknown in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unknown.question)
                                .font(.caption)
                            if !unknown.impact.isEmpty {
                                Text(unknown.impact)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func basisSection(_ draft: HoloContextPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "依据"), systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
            if draft.usedContextRefs.isEmpty && draft.items.allSatisfy({ $0.basis == .generalKnowledge }) {
                Text(String(localized: "本方案基于一般常识，还没有用到你的个人记录。多记录一些情况，方案会更贴合你。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 依据快照（P0）：展示生成时固化的本机命题原文，不再重复条目标题。
                let entries = draft.basisEntries ?? []
                if entries.isEmpty {
                    Text(String(localized: "本次没有引用你的记录，按一般情况整理。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.contextID) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                epistemicBadge(entry.epistemicStatus)
                                if entry.occurrenceStatus == "done" {
                                    Label(String(localized: "本期已完成"), systemImage: "checkmark.seal")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                // 来源坐标（§7.2）：可回源的行给「查看来源」入口
                                if let ref = draft.evidenceRefs?.first(where: { $0.contextID == entry.contextID }),
                                   ref.sourceEntityID != nil {
                                    Spacer(minLength: 0)
                                    Label(
                                        HoloContextEvidenceNavigator.displayName(for: ref.sourceDomain),
                                        systemImage: "arrow.up.right.square"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                                }
                            }
                            Text(entry.statement)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { openEvidence(for: draft, contextID: entry.contextID) }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !draft.coverage.missingScopes.isEmpty {
                Text(String(localized: "未覆盖：\(draft.coverage.missingScopes.joined(separator: "、"))"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 批量「全部加入」：次要快捷操作（§8.1 规则 3），逐条执行、部分失败不回滚。
    private func saveSection(_ draft: HoloContextPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let pendingItems = draft.items.filter { isJoinable($0) }
            if pendingItems.count >= 2 {
                switch batchState {
                case .saved(let count):
                    Label(
                        String(localized: "已添加 \(count) 项到待办"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                case .savedWithFailures(let succeeded, let failed):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            String(localized: "已添加 \(succeeded) 项，\(failed) 项未成功"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Text(String(localized: "未成功的项没有写入，可以再点一次只补失败的部分。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Label(String(localized: "这次没有添加成功"), systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .blocked:
                    Label(String(localized: "方案背景已变化，暂时不能保存"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .idle:
                    Button {
                        performBatchSave(draft, items: pendingItems)
                    } label: {
                        Label(
                            String(localized: "全部加入（\(pendingItems.count) 项）"),
                            systemImage: "square.and.arrow.down.on.square"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if !duplicates.isEmpty {
                Text(String(localized: "提醒：已有相似任务（\(duplicates.joined(separator: "、"))），不会自动合并。"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 该条目当前是否可再加入（已加入/保存中的不算）。
    private func isJoinable(_ item: HoloContextPlanItem) -> Bool {
        guard item.kind == .task || item.kind == .checklistItem else { return false }
        switch itemSaveStates[item.itemID] ?? .idle {
        case .idle, .failed, .taskDeleted:
            return true
        default:
            return false
        }
    }

    /// 纠正三选项（§10）：前两者收起本次草案并持久化（跨会话兑现）；情况变了走 followUp 重新生成。
    private func correctionSection(_ draft: HoloContextPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    resolve(.arranged, runID: draft.runID)
                } label: {
                    Text(String(localized: "已安排好"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Button {
                    resolve(.declined, runID: draft.runID)
                } label: {
                    Text(String(localized: "本次不用"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            Divider()
            HStack(spacing: 8) {
                TextField(String(localized: "情况变了？说说变化，我重新安排"), text: $followUpText)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                Button {
                    regenerate(draft)
                } label: {
                    if regenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "重新生成"))
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || regenerating)
            }
        }
    }

    /// 收起本次草案并持久化纠正状态（重启后不再回到可保存态）。
    private func resolve(_ state: ResolvedState, runID: String) {
        resolvedState = state
        receipts.saveResolution(runID: runID, resolution: state.rawValue)
    }

    private var resolvedLabel: some View {
        Label(
            resolvedState == .arranged
            ? String(localized: "已按你的反馈收起本次方案")
            : String(localized: "本次方案未采用，可随时重新提问"),
            systemImage: resolvedState == .arranged ? "checkmark.circle" : "archivebox"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 情况变了：followUp 重生成（同一 run 推进 requestRevision；失败保持原草案）。
    private func regenerate(_ draft: HoloContextPlanDraft) {
        regenerating = true
        Task { @MainActor in
            defer { regenerating = false }
            guard let outcome = try? await HoloContextChatPlanner.followUp(
                runID: draft.runID,
                utterance: followUpText
            ) else { return }
            draft0 = outcome.draft
            confirmedDates = [:]
            itemSaveStates = [:]
            batchState = .idle
            duplicates = []
            followUpText = ""
            restoreItemStates(for: outcome.draft)
        }
    }

    // MARK: - 动作

    /// 依据行回源（§7.2）：跳原实体详情；不可达时统一交代，不跳空页面。
    private func openEvidence(for draft: HoloContextPlanDraft, contextID: String) {
        guard let ref = draft.evidenceRefs?.first(where: { $0.contextID == contextID }),
              let entityID = ref.sourceEntityID else {
            showEvidenceUnavailable = true
            return
        }
        let navigated = HoloContextEvidenceNavigator.navigate(
            sourceDomain: ref.sourceDomain,
            sourceEntityID: entityID
        )
        if !navigated {
            showEvidenceUnavailable = true
        }
    }

    /// 默认选中策略已随批量唯一入口退役（§8.1 改逐条即时加入）。

    private func loadDraft() {
        guard let json = draftJSON, let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(HoloContextPlanDraft.self, from: data) else { return }
        draft0 = decoded
        // 纠正状态跨会话兑现（P0）：重启后「已安排好/本次不用」不再回到可保存态。
        if let raw = receipts.loadResolution(runID: decoded.runID),
           let restored = ResolvedState(rawValue: raw), restored != .active {
            resolvedState = restored
        }
        restoreItemStates(for: decoded)
        refreshMatterPreparation(for: decoded)
    }

    /// 从回执表恢复每个条目的已加入状态（退出重进不重复创建，§8.1 规则 7）。
    private func restoreItemStates(for draft: HoloContextPlanDraft) {
        var states: [String: HoloContextPlanItemSaveState] = [:]
        let receiptsV2 = receipts.loadReceiptsV2()
        let legacy = receipts.loadReceipts()
        for item in draft.items where item.kind == .task || item.kind == .checklistItem {
            let logicalKey = "\(draft.runID)|\(item.itemID)"
            let fingerprint = HoloContextPlanExecutionAdapter.contentFingerprint(
                item, confirmedDate: confirmedDates[item.itemID]
            )
            if let receipt = receiptsV2[logicalKey], receipt.fingerprint == fingerprint {
                let exists = receipt.taskID.flatMap { taskExists?($0) }
                states[item.itemID] = HoloContextPlanExecutionAdapter.resolveDisplayState(
                    receipt: receipt, taskExists: exists
                )
            } else if let legacyFingerprint = legacy[logicalKey],
                      legacyFingerprint == fingerprint {
                states[item.itemID] = .addedLegacy
            }
        }
        itemSaveStates = states
    }

    // MARK: - Matter 激活区（方案 §13.1）

    /// 灰度关闭 / 纯说明草案 / 已被用户纠正收起时不出现（不制造打扰）。
    @ViewBuilder
    private func matterActivationSection(_ draft: HoloContextPlanDraft) -> some View {
        if HoloMatterRolloutPolicy.activationEnabled, resolvedState == .active {
            switch matterPreparation {
            case .alreadyActivated(let matterID):
                activationDoneStrip(matterID)
            case .ready(let proposedTitle, let proposedDate):
                activationStrip(draft: draft, proposedTitle: proposedTitle, proposedDate: proposedDate, duplicate: nil)
            case .possibleDuplicate(let existingID, let existingTitle, let proposedTitle, let proposedDate):
                activationStrip(
                    draft: draft,
                    proposedTitle: proposedTitle,
                    proposedDate: proposedDate,
                    duplicate: (existingID, existingTitle)
                )
            case nil:
                EmptyView()
            }
        }
    }

    /// 激活入口条（未激活态）。
    private func activationStrip(
        draft: HoloContextPlanDraft,
        proposedTitle: String,
        proposedDate: Date?,
        duplicate: (UUID, String)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(String(localized: "继续整理这件事"))
                    .font(.footnote.weight(.semibold))
                if duplicate != nil {
                    Text(String(localized: "或更新已有的"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(String(localized: "Holo 会记住进展、没解决的问题和下一步。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let (existingID, existingTitle) = duplicate {
                // 去重场景（§11.3）：不猜，把选择交给用户。
                Button {
                    activationExistingMatterID = existingID
                    activationTitle = proposedTitle
                    activationTargetDate = proposedDate
                    startActivation(draft: draft, existingMatterID: existingID)
                } label: {
                    Text(String(localized: "更新到「\(existingTitle)」"))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.holoPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(activationInFlight)

                Button {
                    activationExistingMatterID = nil
                    activationTitle = proposedTitle
                    activationTargetDate = proposedDate
                    showActivationSheet = true
                } label: {
                    Text(String(localized: "仍新建一件"))
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(activationInFlight)
            } else {
                Button {
                    activationExistingMatterID = nil
                    activationTitle = proposedTitle
                    activationTargetDate = proposedDate
                    showActivationSheet = true
                } label: {
                    Text(String(localized: "开始整理"))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.holoPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.holoPrimary.opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(activationInFlight)
            }

            if let error = activationErrorText {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.holoPrimary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.holoPrimary.opacity(0.2), lineWidth: 1)
        )
        .sheet(isPresented: $showActivationSheet) {
            activationConfirmSheet(draft)
        }
    }

    /// 轻确认弹层：只校对标题与目标日期，不做项目管理表单（方案 §13.1）。
    private func activationConfirmSheet(_ draft: HoloContextPlanDraft) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "加入「进行中的事」"))
                        .font(.headline)
                    Text(String(localized: "Holo 会持续记住这件事的进展，你随时可以在里面继续讨论。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "这件事叫什么"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "事项名称"), text: $activationTitle)
                        .font(.subheadline.weight(.medium))
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "大概什么时候"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let date = activationTargetDate {
                        HStack {
                            Text(Self.dateText(date))
                                .font(.subheadline)
                            Spacer()
                            Button(String(localized: "还不确定")) {
                                activationTargetDate = nil
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.holoPrimary)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                    } else {
                        HStack {
                            Text(String(localized: "还不确定，先不填"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            DatePicker("", selection: Binding(
                                get: { activationTargetDate ?? Date().addingTimeInterval(86_400) },
                                set: { activationTargetDate = $0 }
                            ), displayedComponents: .date)
                            .labelsHidden()
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                    }
                }

                Spacer(minLength: 0)

                Button {
                    startActivation(draft: draft, existingMatterID: activationExistingMatterID)
                } label: {
                    if activationInFlight {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    } else {
                        Text(String(localized: "确认开始整理"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                }
                .buttonStyle(.plain)
                .background(Color.holoPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(activationInFlight || activationTitle.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    showActivationSheet = false
                } label: {
                    Text(String(localized: "先不整理"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .presentationDetents([.medium])
        }
    }

    /// 已激活回执条（§13.1：原位显示，可进入详情）。
    private func activationDoneStrip(_ matterID: UUID) -> some View {
        HStack {
            Label(String(localized: "已加入「进行中的事」"), systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
            Spacer()
            Button {
                onOpenMatter?(matterID)
            } label: {
                HStack(spacing: 2) {
                    Text(String(localized: "查看"))
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.08))
        )
    }

    private func refreshMatterPreparation(for draft: HoloContextPlanDraft) {
        guard HoloMatterRolloutPolicy.activationEnabled else { return }
        let coordinator = HoloMatterActivationCoordinator()
        matterPreparation = coordinator.prepare(
            contextPlanMessageID: messageID,
            draft: draft
        )
    }

    private func startActivation(draft: HoloContextPlanDraft, existingMatterID: UUID?) {
        activationInFlight = true
        activationErrorText = nil
        let title = activationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = activationTargetDate
        let userMessage = userMessageID
        Task { @MainActor in
            defer { activationInFlight = false }
            do {
                let coordinator = HoloMatterActivationCoordinator()
                let receipt = try await coordinator.confirm(
                    contextPlanMessageID: messageID,
                    userMessageID: userMessage,
                    draft: draft,
                    confirmedTitle: title,
                    confirmedTargetDate: date,
                    existingMatterID: existingMatterID
                )
                showActivationSheet = false
                matterPreparation = .alreadyActivated(matterID: receipt.matterID)
            } catch {
                activationErrorText = String(localized: "没有整理成功，可以再试一次")
            }
        }
    }

    nonisolated private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    // MARK: - 单项/批量保存

    /// 保存前权限复查（§10）：背景被忘记/更改/闸关闭后不得保存。
    private func canSave(_ draft: HoloContextPlanDraft, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let allowed = await HoloContextChatPlanner.canSave(
                runID: draft.runID,
                draftRevision: draft.draftRevision
            )
            completion(allowed)
        }
    }

    /// 单条任务即时加入（§8.1 主入口）：只创建这一项，成功立即显示回执。
    private func performSingleSave(_ item: HoloContextPlanItem, force: Bool = false) {
        guard let draft = draft0 else { return }
        canSave(draft) { [self] allowed in
            guard allowed else {
                itemSaveStates[item.itemID] = .blocked
                return
            }
            itemSaveStates[item.itemID] = .saving
            let creation = HoloContextPlanTaskCreation(
                idempotencyKey: "\(draft.runID)|v\(draft.draftRevision)|\(item.itemID)",
                logicalItemID: "\(draft.runID)|\(item.itemID)",
                itemID: item.itemID,
                title: item.title,
                note: item.reason.isEmpty ? nil : item.reason,
                dueDate: confirmedDates[item.itemID]
            )
            let results = onCreateTasks([creation])
            applyReceipts(results: results, creations: [creation])
        }
    }

    /// 批量快捷操作（次要入口）：逐条创建、逐条回报，部分失败不回滚已成功项。
    private func performBatchSave(_ draft: HoloContextPlanDraft, items: [HoloContextPlanItem]) {
        canSave(draft) { [self] allowed in
            guard allowed else {
                batchState = .blocked
                return
            }
            let creations = items.map { item in
                HoloContextPlanTaskCreation(
                    idempotencyKey: "\(draft.runID)|v\(draft.draftRevision)|\(item.itemID)",
                    logicalItemID: "\(draft.runID)|\(item.itemID)",
                    itemID: item.itemID,
                    title: item.title,
                    note: item.reason.isEmpty ? nil : item.reason,
                    dueDate: confirmedDates[item.itemID]
                )
            }
            let results = onCreateTasks(creations)
            applyReceipts(results: results, creations: creations)

            let succeeded = creations.filter { results[$0.idempotencyKey]?.succeeded == true }.count
            let failed = creations.count - succeeded
            batchState = failed == 0 ? .saved(succeeded) : (succeeded == 0 ? .failed : .savedWithFailures(succeeded: succeeded, failed: failed))
        }
    }

    /// 按真实回执更新单项状态与 V2 回执表（失败不记回执、不虚报成功）。
    private func applyReceipts(
        results: [String: HoloContextPlanCreationReceipt],
        creations: [HoloContextPlanTaskCreation]
    ) {
        guard let draft = draft0 else { return }
        var receiptsV2 = receipts.loadReceiptsV2()
        var legacyReceipts = receipts.loadReceipts()
        var duplicatesBuffer: [String] = []

        for creation in creations {
            let state: HoloContextPlanItemSaveState
            if let receipt = results[creation.idempotencyKey], receipt.succeeded {
                let taskID = receipt.taskID.flatMap { UUID(uuidString: $0) }
                if let taskID {
                    state = .added(taskID: taskID)
                    receiptsV2[creation.logicalItemID] = HoloContextPlanTaskReceiptV2(
                        logicalItemID: creation.logicalItemID,
                        fingerprint: HoloContextPlanExecutionAdapter.contentFingerprint(
                            item(for: creation, in: draft),
                            confirmedDate: confirmedDates[creation.itemID]
                        ),
                        taskID: taskID,
                        sourceMessageID: messageID,
                        sourceItemID: creation.itemID,
                        createdAt: Date()
                    )
                    // legacy 表同键清理（V2 已覆盖，防旧指纹干扰重试判定）
                    legacyReceipts.removeValue(forKey: creation.logicalItemID)
                } else {
                    // 闭包只回指纹（legacy 落库路径），不伪造任务 ID。
                    state = .addedLegacy
                    legacyReceipts[creation.logicalItemID] = creation.idempotencyKey
                }
            } else {
                state = .failed(message: results[creation.idempotencyKey]?.failureMessage ?? "")
            }
            itemSaveStates[creation.itemID] = state
        }

        // 相似任务提示（不合并，只提醒）。
        let repo = TodoRepository.shared
        let existingTitles = Set(
            (repo.getTodayTasks() + repo.getOverdueTasks())
                .map { HoloContextPlanExecutionAdapter.normalizedTitle($0.title) }
        )
        for creation in creations where existingTitles.contains(HoloContextPlanExecutionAdapter.normalizedTitle(creation.title)) {
            duplicatesBuffer.append(creation.title)
        }
        if !duplicatesBuffer.isEmpty {
            duplicates = duplicatesBuffer
        }

        receipts.saveReceiptsV2(receiptsV2)
        receipts.saveReceipts(legacyReceipts)
    }

    private func item(for creation: HoloContextPlanTaskCreation, in draft: HoloContextPlanDraft) -> HoloContextPlanItem {
        draft.items.first { $0.itemID == creation.itemID }
            ?? HoloContextPlanItem(itemID: creation.itemID, title: creation.title, kind: .task)
    }

    // MARK: - 小件

    private func icon(for kind: HoloContextPlanItemKind) -> String {
        switch kind {
        case .task: return "circle"
        case .checklistItem: return "checklist"
        case .adjustment: return "arrow.triangle.2.circlepath"
        case .information: return "info.circle"
        }
    }

    @ViewBuilder
    private func basisBadge(_ basis: HoloContextPlanBasis) -> some View {
        switch basis {
        case .personalEvidence:
            Label(String(localized: "你的记录"), systemImage: "person.text.rectangle")
                .font(.caption2)
                .foregroundStyle(.tint)
        case .inference:
            Label(String(localized: "推断"), systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .generalKnowledge:
            EmptyView()
        }
    }

    /// 依据快照的认识状态徽标：推断类提示是推测而非事实（限定表达）。
    @ViewBuilder
    private func epistemicBadge(_ raw: String?) -> some View {
        switch raw {
        case "declared":
            Label(String(localized: "你说过"), systemImage: "person.text.rectangle")
                .font(.caption2)
                .foregroundStyle(.tint)
        case "observed":
            Label(String(localized: "你的记录"), systemImage: "person.text.rectangle")
                .font(.caption2)
                .foregroundStyle(.tint)
        case "inferred":
            Label(String(localized: "推测"), systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// 保存回执存储：V2（logicalItemID → 带任务 ID 的回执）+ legacy 指纹兼容 + 纠正状态。
/// 全部本机持久化（UserDefaults），跨草案版本对账（今日看板 Matter 化方案 §8.2）。
struct ContextPlanUserDefaultsReceipts: ContextPlanReceiptStoring {
    private static let key = "holo_personal_context_plan_receipts_v1"
    private static let keyV2 = "holo_personal_context_plan_receipts_v2"
    private static let resolutionKey = "holo_personal_context_plan_resolutions_v1"
    /// 回执容量上限：超限按 createdAt 淘汰最旧（§8.2，禁非确定性淘汰）。
    private static let receiptLimit = 200

    func loadReceipts() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let receipts = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return receipts
    }

    func saveReceipts(_ receipts: [String: String]) {
        if let data = try? JSONEncoder().encode(receipts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func loadReceiptsV2() -> [String: HoloContextPlanTaskReceiptV2] {
        guard let data = UserDefaults.standard.data(forKey: Self.keyV2),
              let receipts = try? JSONDecoder.holoMatter.decode([String: HoloContextPlanTaskReceiptV2].self, from: data)
        else { return [:] }
        return receipts
    }

    func saveReceiptsV2(_ receipts: [String: HoloContextPlanTaskReceiptV2]) {
        let trimmed = HoloContextPlanExecutionAdapter.trimReceipts(receipts, limit: Self.receiptLimit)
        if let data = try? JSONEncoder.holoMatter.encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.keyV2)
        }
    }

    func loadResolution(runID: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: Self.resolutionKey),
              let resolutions = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return resolutions[runID]
    }

    func saveResolution(runID: String, resolution: String) {
        var resolutions: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.resolutionKey),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            resolutions = existing
        }
        // 容量上限：超限时丢弃任意历史条目保持规模（纠正记录无新旧语义差异）。
        if resolutions.count >= 200, resolutions[runID] == nil {
            for old in resolutions.keys.prefix(resolutions.count - 199) {
                resolutions.removeValue(forKey: old)
            }
        }
        resolutions[runID] = resolution
        if let data = try? JSONEncoder().encode(resolutions) {
            UserDefaults.standard.set(data, forKey: Self.resolutionKey)
        }
    }
}

protocol ContextPlanReceiptStoring {
    /// legacy 指纹表（旧版本写入；仅用于对已升级数据的兜底防重复）。
    func loadReceipts() -> [String: String]
    func saveReceipts(_ receipts: [String: String])
    /// V2 回执表（带真实任务 ID 与来源键；Matter 补链依据）。
    func loadReceiptsV2() -> [String: HoloContextPlanTaskReceiptV2]
    func saveReceiptsV2(_ receipts: [String: HoloContextPlanTaskReceiptV2])
    /// 纠正状态跨会话兑现（runID → arranged/declined）。
    func loadResolution(runID: String) -> String?
    func saveResolution(runID: String, resolution: String)
}
