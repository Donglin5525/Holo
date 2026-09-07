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
    /// 保存回执存储（logicalItemID → 内容指纹）。
    let receipts: ContextPlanReceiptStoring
    /// 任务创建出口（返回幂等键 → 真实回执；已发送请求≠成功，卡片按回执更新）。
    let onCreateTasks: ([HoloContextPlanTaskCreation]) -> [String: HoloContextPlanCreationReceipt]

    @State private var draft0: HoloContextPlanDraft?
    @State private var selected: Set<String> = []
    @State private var confirmedDates: [String: Date] = [:]
    @State private var showBasis = false
    @State private var saveState: SaveState = .idle
    @State private var duplicates: [String] = []
    // §10 纠正三选项：「已安排好/本次不用」收起本次草案；「情况变了」走 followUp 重生成。
    @State private var resolvedState: ResolvedState = .active
    @State private var followUpText = ""
    @State private var regenerating = false

    enum SaveState: Equatable {
        case idle
        case saved(Int)
        /// 部分失败：只按真实回执计数，不虚报。
        case savedWithFailures(succeeded: Int, failed: Int)
        case failed
        /// 权限阻断：背景被忘记/更改/闸关闭，旧草案不可保存。
        case blocked
    }

    enum ResolvedState: String, Equatable {
        case active
        case arranged
        case declined
    }

    var body: some View {
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
        .onAppear { loadDraft() }
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
            if isTask {
                Button {
                    if selected.contains(item.itemID) {
                        selected.remove(item.itemID)
                    } else {
                        selected.insert(item.itemID)
                    }
                } label: {
                    Image(systemName: selected.contains(item.itemID)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .foregroundStyle(selected.contains(item.itemID) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: icon(for: item.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    DatePicker(
                        String(localized: "定个日期（可选）"),
                        selection: Binding(
                            get: { confirmedDates[item.itemID] ?? Date() },
                            set: { confirmedDates[item.itemID] = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .font(.caption2)
                }
            }
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

    private func saveSection(_ draft: HoloContextPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch saveState {
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
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        String(localized: "这次没有添加成功"),
                        systemImage: "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    Text(String(localized: "任务没有写入，稍后再试或到待办页手动创建。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .blocked:
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        String(localized: "方案背景已变化，暂时不能保存"),
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Text(String(localized: "你的记忆设置或相关记录有更新，重新提问生成新方案即可。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .idle:
                Button {
                    save(draft)
                } label: {
                    Label(
                        String(localized: "添加选中的 \(selected.count) 项到待办"),
                        systemImage: "square.and.arrow.down"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                if !duplicates.isEmpty {
                    Text(String(localized: "提醒：已有相似任务（\(duplicates.joined(separator: "、"))），不会自动合并。"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
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
            selected = Set(outcome.draft.items
                .filter { $0.kind == .task || $0.kind == .checklistItem }
                .map(\.itemID))
            confirmedDates = [:]
            saveState = .idle
            duplicates = []
            followUpText = ""
        }
    }

    // MARK: - 动作

    private func loadDraft() {
        guard let json = draftJSON, let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(HoloContextPlanDraft.self, from: data) else { return }
        draft0 = decoded
        // 默认选中待办/清单项。
        selected = Set(decoded.items
            .filter { $0.kind == .task || $0.kind == .checklistItem }
            .map(\.itemID))
        // 纠正状态跨会话兑现（P0）：重启后「已安排好/本次不用」不再回到可保存态。
        if let raw = receipts.loadResolution(runID: decoded.runID),
           let restored = ResolvedState(rawValue: raw), restored != .active {
            resolvedState = restored
        }
    }

    private func save(_ draft: HoloContextPlanDraft) {
        Task { @MainActor in
            // 权限阻断复查（§10）：背景被忘记/更改/闸关闭后不得保存。
            guard await HoloContextChatPlanner.canSave(
                runID: draft.runID,
                draftRevision: draft.draftRevision
            ) else {
                saveState = .blocked
                return
            }
            performSave(draft)
        }
    }

    private func performSave(_ draft: HoloContextPlanDraft) {
        var request = HoloContextPlanExecutionRequest(
            runID: draft.runID,
            draftRevision: draft.draftRevision,
            items: [],
            confirmedDates: confirmedDates
        )
        request.items = draft.items.map { item in
            var mutable = item
            mutable.selected = selected.contains(item.itemID)
            return mutable
        }
        let repo = TodoRepository.shared
        let existingTitles = Set(
            (repo.getTodayTasks() + repo.getOverdueTasks())
                .map { HoloContextPlanExecutionAdapter.normalizedTitle($0.title) }
        )
        let outcome = HoloContextPlanExecutionAdapter.prepare(
            request: request,
            successfulReceipts: receipts.loadReceipts(),
            existingTaskTitles: existingTitles
        )
        let results = onCreateTasks(outcome.creations)
        // 回执以仓储写入结果为准：失败不记、不虚报（纯逻辑在 Adapter，可 standalone 测试）。
        let reconciliation = HoloContextPlanExecutionAdapter.reconcileReceipts(
            creations: outcome.creations,
            results: results,
            existingReceipts: receipts.loadReceipts(),
            items: draft.items,
            confirmedDates: confirmedDates
        )
        if reconciliation.hasNewSuccesses {
            receipts.saveReceipts(reconciliation.updatedReceipts)
        }
        duplicates = outcome.possibleDuplicateTitles
        switch (reconciliation.succeededCount, reconciliation.failedCount) {
        case (_, 0): saveState = .saved(reconciliation.succeededCount)
        case (0, _): saveState = .failed
        default:
            saveState = .savedWithFailures(
                succeeded: reconciliation.succeededCount,
                failed: reconciliation.failedCount
            )
        }
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

/// 保存回执存储：logicalItemID → 内容指纹（UserDefaults 本机，跨草案版本对账）。
/// 纠正状态（runID → arranged/declined）同在本机持久化，跨会话兑现。
struct ContextPlanUserDefaultsReceipts: ContextPlanReceiptStoring {
    private static let key = "holo_personal_context_plan_receipts_v1"
    private static let resolutionKey = "holo_personal_context_plan_resolutions_v1"

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
    func loadReceipts() -> [String: String]
    func saveReceipts(_ receipts: [String: String])
    /// 纠正状态跨会话兑现（runID → arranged/declined）。
    func loadResolution(runID: String) -> String?
    func saveResolution(runID: String, resolution: String)
}
