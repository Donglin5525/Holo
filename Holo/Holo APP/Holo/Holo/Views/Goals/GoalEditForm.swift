//
//  GoalEditForm.swift
//  Holo
//
//  目标字段编辑表单（可复用）
//  同时服务于「手动创建目标」和「编辑已有目标核心字段」两个场景。
//  本表单只操作 GoalDraft（值类型），保存动作由调用方决定：
//    - 创建模式：调 GoalRepository.saveDraft
//    - 编辑模式：调 GoalRepository.updateFields
//

import SwiftUI

struct GoalEditForm: View {
    @Binding var draft: GoalDraft

    /// 截止日期用 Date 驱动 DatePicker，与 draft.deadlineText("yyyy-MM-dd") 双向同步
    @State private var deadlineDate: Date

    /// 数值输入用文本驱动（draft 存 Double），避免输入中途 "3." 被解析回写打断
    @State private var metricTargetText: String
    @State private var metricBaselineText: String

    /// habit 源可挂的数值习惯（活跃未归档；onAppear 加载一次，避免 body 里反复 fetch）
    @State private var numericHabits: [Habit] = []

    @State private var showIconPicker = false

    init(draft: Binding<GoalDraft>) {
        self._draft = draft
        let parsed = GoalEditForm.parseDeadlineText(draft.wrappedValue.deadlineText)
        self._deadlineDate = State(initialValue: parsed)
        self._metricTargetText = State(
            initialValue: draft.wrappedValue.metricTargetValue.map(GoalMetricEvaluator.formatValue) ?? ""
        )
        self._metricBaselineText = State(
            initialValue: draft.wrappedValue.metricBaselineValue.map(GoalMetricEvaluator.formatValue) ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "target", title: "目标信息")

            CardDivider()

            // 目标类型
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("目标类型")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Picker("目标类型", selection: $draft.goalKind) {
                    ForEach(GoalKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text(draft.goalKind.descriptor)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                if draft.isQuantitative {
                    metricFields
                        .onChange(of: draft.goalKind) { _, newKind in
                            // 类型切换后数据源不在可选集时回落手动（达标型没有账本源）
                            if !GoalMetricSource.selectable(for: newKind).contains(draft.metricSource) {
                                draft.metricSource = .manual
                            }
                            if draft.metricSource != .habit { draft.sourceHabitId = nil }
                        }
                }
            }

            // 标题
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("标题")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标标题", text: $draft.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 领域
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("领域")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Picker("领域", selection: $draft.domain) {
                    ForEach(GoalDomain.allCases) { domain in
                        HStack(spacing: 6) {
                            Image(systemName: domain.icon)
                            Text(domain.displayName)
                        }
                        .tag(domain)
                    }
                }
                .pickerStyle(.menu)
            }

            // 图标
            HStack(spacing: HoloSpacing.md) {
                Button {
                    showIconPicker = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        Text(draft.iconEmoji ?? draft.domain.defaultEmoji)
                            .font(.system(size: 22))
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoBackground)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("图标")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Text(draft.iconEmoji == nil ? "默认（按领域）" : "已自定义")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .buttonStyle(.plain)

                if draft.iconEmoji != nil {
                    Button {
                        draft.iconEmoji = nil
                    } label: {
                        Text("恢复默认")
                            .font(.holoCaption)
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .sheet(isPresented: $showIconPicker) {
                EmojiIconPickerSheet(currentIcon: draft.iconEmoji ?? draft.domain.defaultEmoji) { emoji in
                    draft.iconEmoji = emoji
                }
            }

            // 说明
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("说明")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标说明（可选）", text: Binding(
                    get: { draft.summary ?? "" },
                    set: { draft.summary = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 期望结果
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("期望结果")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("达成后是什么样", text: Binding(
                    get: { draft.desiredOutcome ?? "" },
                    set: { draft.desiredOutcome = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 动机
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("动机")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("为什么要这个目标", text: Binding(
                    get: { draft.motivation ?? "" },
                    set: { draft.motivation = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 截止日期
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("截止日期")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                DatePicker(
                    "截止日期",
                    selection: $deadlineDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .onChange(of: deadlineDate) { _, newDate in
                    draft.deadlineText = GoalEditForm.formatDeadline(newDate)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - 量化字段

    /// 量化配置区：目标值+单位 → 数据来源；达标型额外抓一次基线。
    /// habit 源列出数值习惯并按口径给行内提示；ledger 源明示账本口径
    @ViewBuilder
    private var metricFields: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text(draft.goalKind == .target ? "目标值" : "目标总量")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    TextField(draft.goalKind == .target ? "如 70" : "如 300", text: $metricTargetText)
                        .keyboardType(.decimalPad)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .padding(HoloSpacing.sm)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                        .onChange(of: metricTargetText) { _, newText in
                            draft.metricTargetValue = Double(newText)
                        }
                }

                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text("单位")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    TextField("km / kg / 元", text: Binding(
                        get: { draft.metricUnit ?? "" },
                        set: { draft.metricUnit = $0.isEmpty ? nil : $0 }
                    ))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .padding(HoloSpacing.sm)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                }
            }

            if draft.goalKind == .target {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text("当前值（基线）")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    TextField("如 75", text: $metricBaselineText)
                        .keyboardType(.decimalPad)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .padding(HoloSpacing.sm)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                        .onChange(of: metricBaselineText) { _, newText in
                            draft.metricBaselineValue = Double(newText)
                        }
                    Text("以现在为起点，之后记录当前水平，进度按「已变多少 / 共需变多少」计算")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("数据来源")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Picker("数据来源", selection: $draft.metricSource) {
                    ForEach(GoalMetricSource.selectable(for: draft.goalKind)) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)

                if draft.metricSource == .habit {
                    habitSourcePicker
                } else if draft.metricSource == .ledger {
                    Text("按全账本净结余计算（含信用卡负债）")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.top, HoloSpacing.xs)
        .onAppear {
            let repo = HabitRepository.shared
            repo.setup()
            numericHabits = repo.activeHabits.filter { $0.isNumericType }
            // 源习惯已被删除/归档时不让死 ID 原样通过校验，强制重选
            if let id = draft.sourceHabitId, !numericHabits.contains(where: { $0.id == id }) {
                draft.sourceHabitId = nil
            }
        }
    }

    /// habit 源的习惯选择：只列数值习惯；换习惯时达标型自动抓基线，口径错配给行内提示不硬拦
    @ViewBuilder
    private var habitSourcePicker: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            if numericHabits.isEmpty {
                Text("还没有数值型习惯，先到习惯模块创建一个再来挂载")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Picker("源习惯", selection: $draft.sourceHabitId) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(numericHabits, id: \.id) { habit in
                        Text("\(habit.name)（\(habit.unitText.isEmpty ? "无单位" : habit.unitText)）")
                            .tag(UUID?.some(habit.id))
                    }
                }
                .pickerStyle(.menu)

                if let mismatch = aggregationMismatchText {
                    Text(mismatch)
                        .font(.holoCaption)
                        .foregroundColor(.orange)
                }
            }
        }
        .onChange(of: draft.sourceHabitId) { _, newId in
            // 达标型换源习惯：基线跟着换（抓创建前最新记录，抓不到保留手填值）
            guard draft.goalKind == .target,
                  let newId,
                  let habit = numericHabits.first(where: { $0.id == newId }),
                  let latest = HabitRepository.shared.getLatestValue(for: habit, before: Date()) else { return }
            metricBaselineText = GoalMetricEvaluator.formatValue(latest)
            draft.metricBaselineValue = latest
        }
    }

    /// 口径错配提示：累积型建议 sum 习惯、达标型建议 latest 习惯，选错只提醒不拦
    private var aggregationMismatchText: String? {
        guard let habitId = draft.sourceHabitId,
              let habit = numericHabits.first(where: { $0.id == habitId }) else { return nil }
        switch draft.goalKind {
        case .process:
            return nil
        case .cumulative:
            guard habit.isMeasureType else { return nil }
            return "「\(habit.name)」是测量类习惯（每日取最新值），做累计源会把每天的值加总"
        case .target:
            guard habit.isCountType else { return nil }
            return "「\(habit.name)」是计数类习惯（当日累加），做达标源只取最新一条记录值"
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
    }

    // MARK: - Deadline 转换

    /// "yyyy-MM-dd" → Date，解析失败回退到今天
    static func parseDeadlineText(_ text: String?) -> Date {
        guard let text, !text.isEmpty else { return Date() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? Date()
    }

    /// Date → "yyyy-MM-dd"
    static func formatDeadline(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 从已有 Goal 构造 draft（编辑模式用）
    static func draft(from goal: Goal) -> GoalDraft {
        let deadlineText: String? = {
            guard let deadline = goal.deadline else { return nil }
            return formatDeadline(deadline)
        }()
        return GoalDraft(
            id: goal.id.uuidString,
            title: goal.title,
            summary: goal.summary,
            domain: goal.goalDomain,
            iconEmoji: goal.iconEmoji,
            desiredOutcome: goal.desiredOutcome,
            motivation: goal.motivation,
            deadlineText: deadlineText,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: goal.goalKindEnum,
            metricSource: goal.metricSourceEnum,
            metricUnit: goal.metricUnit,
            metricTargetValue: goal.metricTargetValueDouble,
            metricBaselineValue: goal.baselineValueDouble,
            sourceHabitId: goal.sourceHabitId
        )
    }

    /// 构造空 draft（手动创建模式用）
    static func emptyDraft() -> GoalDraft {
        GoalDraft(
            id: UUID().uuidString,
            title: "",
            summary: nil,
            domain: .other,
            iconEmoji: nil,
            desiredOutcome: nil,
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: []
        )
    }

    /// 量化字段可保存校验：量化时目标值必填且 >0；达标型基线必填（允许 0，如引体向上从 0 个起步）；
    /// habit 源必选一个源习惯
    static func metricFieldsValid(in draft: GoalDraft) -> Bool {
        guard draft.isQuantitative else { return true }
        guard let target = draft.metricTargetValue, target > 0 else { return false }
        if draft.goalKind == .target {
            guard let baseline = draft.metricBaselineValue, baseline != target else { return false }
        }
        if draft.metricSource == .habit, draft.sourceHabitId == nil {
            return false
        }
        return true
    }
}
