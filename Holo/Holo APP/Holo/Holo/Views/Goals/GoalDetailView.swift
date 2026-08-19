//
//  GoalDetailView.swift
//  Holo
//
//  目标详情视图：状态操作、关联任务/习惯、AI 授权开关
//

import SwiftUI

struct GoalDetailView: View {
    @ObservedObject private var repository = GoalRepository.shared
    @ObservedObject var goal: Goal
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    let onDeleteRequested: (UUID) -> Void
    @State private var showDeleteConfirm = false
    @State private var operationError: String?
    @State private var showEditForm = false
    @State private var showLinkManager = false
    @State private var showMetricLogSheet = false

    init(
        goal: Goal,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        onDeleteRequested: @escaping (UUID) -> Void = { _ in }
    ) {
        self.goal = goal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self.onDeleteRequested = onDeleteRequested
    }

    var body: some View {
        let progress = GoalProgressEvaluator.evaluate(goal: goal)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                header(progress)
                aiContextToggle
                proactiveNudgeToggle
                taskSection
                habitSection
                metricLogSection
                actionSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle("目标详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除目标", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除目标", role: .destructive) {
                onDeleteRequested(goal.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .sheet(isPresented: $showEditForm) {
            GoalEditSheet(goal: goal) {
                showEditForm = false
            }
        }
        .sheet(isPresented: $showLinkManager) {
            GoalLinkManagerSheet(goal: goal)
        }
        .sheet(isPresented: $showMetricLogSheet) {
            GoalMetricLogSheet(goal: goal)
        }
    }

    private func header(_ progress: GoalProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(goal.title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            if let summary = goal.summary, !summary.isEmpty {
                Text(summary)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            if goal.isQuantitative, let metric = GoalMetricEvaluator.evaluate(goal: goal) {
                metricProgressCard(metric)
            } else if GoalMetricEvaluator.isHabitSourceUnavailable(goal: goal) {
                sourceUnavailableRow
            } else {
                Text("\(progress.state.displayName) · \(progress.taskSummary) · \(progress.habitSummary)")
                    .font(.system(size: 13))
                    .foregroundColor(.holoPrimary)
            }
            if let desiredOutcome = goal.desiredOutcome, !desiredOutcome.isEmpty {
                infoLine(icon: "checkmark.seal", label: "期望结果", value: desiredOutcome)
            }
            if let motivation = goal.motivation, !motivation.isEmpty {
                infoLine(icon: "heart", label: "动机", value: motivation)
            }
            if let deadline = goal.deadline {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: deadline)).day ?? 0
                infoLine(
                    icon: "calendar",
                    label: "截止日期",
                    value: days >= 0 ? "\(GoalEditForm.formatDeadline(deadline))（还剩 \(days) 天）" : "\(GoalEditForm.formatDeadline(deadline))（已逾期 \(-days) 天）"
                )
            }
        }
    }

    private func infoLine(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 16)
            Text("\(label)：")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiContextToggle: some View {
        Toggle("允许 HoloAI 后续参考此目标", isOn: Binding(
            get: { goal.allowAIContext },
            set: { newValue in
                perform {
                    try repository.updateAIContext(goal, allow: newValue)
                }
            }
        ))
        .font(.holoBody)
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private var proactiveNudgeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("允许 HoloAI 主动围绕此目标提醒（含系统通知）", isOn: Binding(
                get: { goal.allowAIContext && goal.proactiveNudge },
                set: { newValue in
                    perform {
                        try repository.updateProactiveNudge(goal, enabled: newValue)
                    }
                }
            ))
            .font(.holoBody)
            .disabled(!goal.allowAIContext)

            if !goal.allowAIContext {
                Text("需先开启「允许 HoloAI 参考此目标」")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.leading, 4)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(title: "关联任务")
            if goal.sortedTasks.isEmpty {
                Text("暂无关联任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedTasks, id: \.id) { task in
                    linkedEntityRow(title: task.title, icon: "checklist") {
                        onOpenLinkedEntity(.taskDetail(taskId: task.id))
                    }
                }
            }
        }
    }

    private var habitSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(title: "关联习惯")
            if goal.sortedHabits.isEmpty {
                Text("暂无关联习惯")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedHabits, id: \.id) { habit in
                    linkedEntityRow(title: habit.name, icon: "checkmark.circle") {
                        onOpenLinkedEntity(.habitDetail(habitId: habit.id))
                    }
                }
            }
        }
    }

    // MARK: - 量化目标

    private var unitDisplay: String {
        goal.metricUnit.map { " \($0)" } ?? ""
    }

    /// 量化目标头部：大数字进度区（当前值/目标值 + 环形进度 + 预计达成 + 记一笔入口）
    private func metricProgressCard(_ metric: GoalMetricProgress) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.lg) {
                GoalMetricRingView(progress: metric.progress)

                VStack(alignment: .leading, spacing: 4) {
                    Text(metricHeadlineText(metric))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if goal.goalKindEnum == .target {
                        // 达标型基线视角：已减 2.5 kg / 共 5 kg，而非从 0 起的百分比
                        Text(metricBaselineText(metric))
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    } else {
                        Text("已完成 \(Int((metric.progress * 100).rounded()))%")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                Spacer(minLength: 0)
            }

            metricForecastLine(metric)

            if goal.metricSourceEnum == .manual {
                Button {
                    showMetricLogSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                        Text("记一笔")
                            .font(.holoBody)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
            } else {
                metricSourceLabel
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoPrimary.opacity(0.2), lineWidth: 1)
        )
    }

    /// 大数字行：累积型「128.5 / 300 km」；达标型「72.5 kg · 目标 70」
    private func metricHeadlineText(_ metric: GoalMetricProgress) -> String {
        if goal.goalKindEnum == .target {
            return "\(GoalMetricEvaluator.formatValue(metric.currentValue))\(unitDisplay) · 目标 \(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))"
        }
        return "\(GoalMetricEvaluator.formatValue(metric.currentValue)) / \(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))\(unitDisplay)"
    }

    private func metricBaselineText(_ metric: GoalMetricProgress) -> String {
        guard let baseline = goal.baselineValueDouble else { return "" }
        let target = goal.metricTargetValueDouble ?? 0
        let verb = target < baseline ? "已减" : "已增"
        let moved = abs(baseline - metric.currentValue)
        let total = abs(target - baseline)
        return "\(verb) \(GoalMetricEvaluator.formatValue(moved))\(unitDisplay) / 共 \(GoalMetricEvaluator.formatValue(total))\(unitDisplay)"
    }

    /// 预计达成行：已达成 / 按节奏外推 / 低速段不预测
    @ViewBuilder
    private func metricForecastLine(_ metric: GoalMetricProgress) -> some View {
        if metric.isAchieved {
            forecastLabel(icon: "checkmark.circle.fill", color: .green, text: "已达成目标")
        } else if let forecast = metric.forecast {
            let dateText = GoalMetricEvaluator.displayDateFormatter.string(from: forecast.predictedDate)
            if let meets = forecast.meetsDeadline {
                if meets {
                    forecastLabel(icon: "checkmark.circle.fill", color: .green, text: "按当前节奏预计 \(dateText) 达成，赶在截止前")
                } else {
                    forecastLabel(icon: "exclamationmark.triangle.fill", color: .orange, text: "照目前进度难以在截止前达成，按当前节奏预计 \(dateText) 达成")
                }
            } else {
                forecastLabel(icon: "chart.line.uptrend.xyaxis", color: .holoPrimary, text: "按当前节奏预计 \(dateText) 达成")
            }
        } else {
            // 进度 <10% 低速段：预测波动大，只提示不输出结论
            forecastLabel(icon: "leaf", color: .holoTextSecondary, text: "刚起步，多记几笔再看趋势")
        }
    }

    private func forecastLabel(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 13))
        }
        .foregroundColor(color)
    }

    /// 自动源（habit/ledger）的来源标签：可点跳源；
    /// 自动源不叠加手动补录（单一事实来源），所以不显示「记一笔」
    @ViewBuilder
    private var metricSourceLabel: some View {
        switch goal.metricSourceEnum {
        case .manual:
            EmptyView()
        case .habit:
            if let habit = GoalMetricEvaluator.sourceHabit(for: goal) {
                Button {
                    onOpenLinkedEntity(.habitDetail(habitId: habit.id))
                } label: {
                    sourceLabelRow(text: "数据来自：\(habit.name)")
                }
                .buttonStyle(.plain)
            }
        case .ledger:
            Button {
                onOpenLinkedEntity(.finance)
            } label: {
                sourceLabelRow(text: "数据来自：账本（按全账本净结余计算，含信用卡负债）")
            }
            .buttonStyle(.plain)
        }
    }

    private func sourceLabelRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
    }

    /// habit 源失效（习惯被删/归档）：进度暂停计算，给重新选择数据源的入口
    private var sourceUnavailableRow: some View {
        Button {
            showEditForm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text("数据源习惯已删除或归档，进度暂停计算，点此重新选择")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(HoloSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
    }

    /// 手动源的记录列表（可删除误记，删除后进度实时重算）
    @ViewBuilder
    private var metricLogSection: some View {
        if goal.isQuantitative && goal.metricSourceEnum == .manual {
            let logs = repository.getMetricLogs(for: goal)
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack {
                    Text("记录")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(logs.count) 条")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                if logs.isEmpty {
                    Text("还没有记录，点「记一笔」开始")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                } else {
                    ForEach(logs, id: \.id) { log in
                        metricLogRow(log)
                    }
                }
            }
        }
    }

    private func metricLogRow(_ log: GoalMetricLog) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(goal.goalKindEnum == .target ? "" : "+ ")\(GoalMetricEvaluator.formatValue(log.value))\(unitDisplay)")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    Text(GoalMetricEvaluator.displayDateFormatter.string(from: log.date))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                if let note = log.note, !note.isEmpty {
                    Text(note)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                perform { try repository.deleteMetricLog(log, for: goal) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title).font(.holoBody).fontWeight(.semibold)
            Spacer()
            Button("管理") {
                showLinkManager = true
            }
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
        }
    }

    private var actionSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button("编辑目标") {
                showEditForm = true
            }
            if goal.goalStatus == .active {
                Button("暂停目标") {
                    perform { try repository.updateStatus(goal, status: .paused) }
                }
            } else if goal.goalStatus == .paused {
                Button("恢复目标") {
                    perform { try repository.updateStatus(goal, status: .active) }
                }
            }
            if goal.goalStatus != .completed {
                Button("标记完成") {
                    perform { try repository.updateStatus(goal, status: .completed) }
                }
            }
            Button("删除目标", role: .destructive) { showDeleteConfirm = true }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkedEntityRow(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(.holoPrimary)
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            GoalNotificationService.broadcastGoalDataChange()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

// MARK: - 量化目标进度环

/// 数字进度的环形呈现（trim 写法对齐 TripleHealthRingView，中心显示百分比）
private struct GoalMetricRingView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.holoDivider, lineWidth: 10)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.holoPrimary,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: progress)

            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 72, height: 72)
    }
}

// MARK: - 编辑目标 Sheet

struct GoalEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal
    @State private var draft: GoalDraft
    @State private var isSaving = false
    @State private var saveError: String?
    let onSaved: () -> Void

    init(goal: Goal, onSaved: @escaping () -> Void) {
        self.goal = goal
        self.onSaved = onSaved
        self._draft = State(initialValue: GoalEditForm.draft(from: goal))
    }

    private var canSave: Bool {
        !isSaving
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GoalEditForm.metricFieldsValid(in: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    GoalEditForm(draft: $draft)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            .background(Color.holoBackground)
            .navigationTitle("编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    save()
                } label: {
                    Text(isSaving ? "保存中" : "保存修改")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .disabled(!canSave)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoCardBackground)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                // deadline 从 draft.deadlineText 解析；nil 表示清空
                let parsedDeadline: Date?? = {
                    guard let text = draft.deadlineText, !text.isEmpty else { return .some(nil) }
                    return .some(GoalEditForm.parseDeadlineText(text))
                }()
                // 量化字段随表单整体保存：切回过程型时 updateFields 内部清空量化配置
                try GoalRepository.shared.updateFields(
                    goal,
                    title: draft.title,
                    summary: draft.summary,
                    domain: draft.domain,
                    iconEmoji: draft.iconEmoji,
                    desiredOutcome: draft.desiredOutcome,
                    motivation: draft.motivation,
                    deadline: parsedDeadline,
                    goalKind: draft.goalKind,
                    metricUnit: draft.isQuantitative ? .some(draft.metricUnit) : nil,
                    metricTargetValue: draft.isQuantitative ? .some(draft.metricTargetValue) : nil,
                    metricBaselineValue: (draft.isQuantitative && draft.goalKind == .target)
                        ? .some(draft.metricBaselineValue) : nil,
                    metricSource: draft.isQuantitative ? draft.metricSource : nil,
                    sourceHabitId: draft.isQuantitative
                        ? .some(draft.metricSource == .habit ? draft.sourceHabitId : nil) : nil
                )
                isSaving = false
                GoalNotificationService.broadcastGoalDataChange()
                onSaved()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
