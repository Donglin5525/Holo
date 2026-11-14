//
//  GoalEditForm.swift
//  Holo
//
//  目标创建/编辑表单（2026-11-13 目标界面减法重设计 S2+S3，规格 §四）
//  一句话大输入 → 类型三选卡 →（数字提示行，条件）→ 条件数字区（按类型浮现）→ 期限行。
//  只操作 GoalDraft（值类型），保存动作由调用方决定：
//    - 创建模式：调 GoalRepository.saveDraft
//    - 编辑模式：调 GoalRepository.updateFields
//  说明/期望结果/动机/图标/AI 上下文五字段已移至 GoalSettingsSheet（S5 接入详情页设置）。
//

import SwiftUI

/// 数字/单位占位是纯占位符号（三语一致），不走本地化——传 String 变量走
/// TextField 的 StringProtocol 重载，避免被提取为 xcstrings key（R7）
private enum MetricPlaceholder {
    static let cumulativeTarget = "300"
    static let cumulativeUnit = "km"
    static let targetBaseline = "75"
    static let targetTarget = "70"
    static let targetUnit = "kg"
}

struct GoalEditForm: View {
    @Binding var draft: GoalDraft

    /// 截止日期用 Date 驱动 DatePicker，与 draft.deadlineText("yyyy-MM-dd") 双向同步
    @State private var deadlineDate: Date

    /// 数值输入用文本驱动（draft 存 Double），避免输入中途 "3." 被解析回写打断
    @State private var metricTargetText: String
    @State private var metricBaselineText: String

    /// 挂习惯自动取基线时「现在」框下方的来源注释（取自「××」最新记录（M/d））
    @State private var baselineNote: String?

    /// habit 源可挂的数值习惯（活跃未归档；onAppear 加载一次，避免 body 里反复 fetch）
    @State private var numericHabits: [Habit] = []

    /// decimalPad 无收起键：键盘附件「完成」统一收起（规格 B3）
    @FocusState private var isFieldFocused: Bool

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
        VStack(alignment: .leading, spacing: 0) {
            bigInput

            Text("这个目标怎么算进度？")
                .goalJourneyText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, 20)

            typeCards
                .padding(.top, 8)

            if let hintNumber = activeHintNumber {
                cumulativeHintRow(hintNumber)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            if draft.isQuantitative {
                metricSection
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            deadlineRow
                .padding(.top, 20)
        }
        .animation(.easeInOut(duration: 0.2), value: draft.isQuantitative)
        .animation(.easeInOut(duration: 0.2), value: activeHintNumber)
        .onAppear(perform: loadHabits)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { isFieldFocused = false }
            }
        }
    }

    // MARK: - 大输入（规格 B2：无框 25pt medium tracking -0.6，两行封顶）

    private var bigInput: some View {
        TextField(
            String(localized: "想做成什么？"),
            text: $draft.title,
            prompt: Text(String(localized: "想做成什么？")).foregroundStyle(Color.holoTextPlaceholder),
            axis: .vertical
        )
        .goalJourneyText(.story)
        .foregroundStyle(Color.holoToolText)
        .lineLimit(2)
        .focused($isFieldFocused)
        .padding(.vertical, 4)
        .frame(minHeight: 48, alignment: .topLeading)
    }

    // MARK: - 类型三选卡（规格 B2：三等宽间距 8、圆角 12、minHeight 60）

    private var typeCards: some View {
        HStack(spacing: 8) {
            GoalKindCard(title: String(localized: "过程型"), example: String(localized: "靠行动推进"),
                         isSelected: draft.goalKind == .process) { selectKind(.process) }
            GoalKindCard(title: String(localized: "累积型"), example: String(localized: "如 跑 300km"),
                         isSelected: draft.goalKind == .cumulative) { selectKind(.cumulative) }
            GoalKindCard(title: String(localized: "达标型"), example: String(localized: "如 减到 70kg"),
                         isSelected: draft.goalKind == .target) { selectKind(.target) }
        }
    }

    /// 切换类型永不改写用户已输入的标题与数字（规格 B3 硬规则）；
    /// 数据回落沿用现状：来源不在可选集回落手动，非 habit 源清空源习惯
    private func selectKind(_ kind: GoalKind) {
        draft.goalKind = kind
        if !GoalMetricSource.selectable(for: kind).contains(draft.metricSource) {
            draft.metricSource = .manual
        }
        if draft.metricSource != .habit {
            draft.sourceHabitId = nil
            baselineNote = nil
        }
    }

    // MARK: - 数字提示行（规格 B3：过程型 + 标题含 ≥阈值 数字 → 建议切累积型）

    /// 当前命中的提示数字；nil=不显示提示行
    private var activeHintNumber: Int? {
        Self.showsCumulativeHint(in: draft)
            ? Self.cumulativeHintNumber(inTitle: draft.title) : nil
    }

    /// 提示行：13pt 行动色 + 行首 sparkles 14pt，整行可点（规格 B2/B3）
    private func cumulativeHintRow(_ number: Int) -> some View {
        Button {
            applyCumulativeHint(number)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                Text("标题里有 \(number) —— 点一下切到「累积型」来追踪进度")
                    .goalJourneyText(.metadata)
                    .lineLimit(2)
            }
            .foregroundStyle(GoalJourneyStyle.action)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }

    /// 提示行点击：切累积型 + 「目标」框为空时预填该数字（有值绝不覆盖，规格 B3）；
    /// 顺带做单位微型映射（公里→km、公斤/kg→kg、元/块→¥、本/次/页原样），
    /// 命中且单位为空才填，不命中留空（R5）；切换后类型非过程型，提示行随条件消失
    private func applyCumulativeHint(_ number: Int) {
        selectKind(.cumulative)
        if metricTargetText.isEmpty {
            metricTargetText = GoalMetricEvaluator.formatValue(Double(number))
        }
        if (draft.metricUnit ?? "").isEmpty, let unit = Self.unitKeyword(in: draft.title) {
            draft.metricUnit = unit
        }
    }

    /// 标题单位词微型映射（R5）：按包含关系命中第一个词表项；nil=不命中留空
    static func unitKeyword(in title: String) -> String? {
        let table: [(String, String)] = [
            ("公里", "km"), ("kg", "kg"), ("公斤", "kg"),
            ("元", "¥"), ("块", "¥"),
            ("本", "本"), ("次", "次"), ("页", "页"),
        ]
        let lower = title.lowercased()
        return table.first { lower.contains($0.0) }?.1
    }

    /// 提示行数字阈值：标题数字 ≥ 此值才建议切累积型。
    /// 演示值，后续按单位词表调优（防「每天读 20 分钟书」类过程型标题误触发）
    static let cumulativeHintNumberThreshold = 30

    /// 标题里首个 ≥ 阈值的数字串取值（只认 ASCII 数字——Character.isNumber 对
    /// 全角数字/罗马数字等也返回 true，中文数字标题不得触发）；nil=无
    static func cumulativeHintNumber(inTitle title: String) -> Int? {
        var runs: [Substring] = []
        var start: Substring.Index?
        for index in title.indices {
            let ch = title[index]
            if ch.isASCII, ch.isNumber {
                if start == nil { start = index }
            } else if let s = start {
                runs.append(title[s..<index])
                start = nil
            }
        }
        if let s = start { runs.append(title[s...]) }
        return runs.lazy.compactMap { Int($0) }.first { $0 >= cumulativeHintNumberThreshold }
    }

    /// 提示行显示条件（规格 B3）：类型停在过程型 + 目标数字未填 + 标题提取到 ≥阈值 数字。
    /// 切换类型/数字出现后条件即不成立，提示行消失
    static func showsCumulativeHint(in draft: GoalDraft) -> Bool {
        draft.goalKind == .process
            && draft.metricTargetValue == nil
            && cumulativeHintNumber(inTitle: draft.title) != nil
    }

    // MARK: - 条件数字区（仅量化类型；规格 B2/B3）

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.goalKind == .cumulative {
                metricFieldContainer {
                    fieldLabel(String(localized: "目标"))
                    targetNumberField(placeholder: MetricPlaceholder.cumulativeTarget)
                    unitField(placeholder: MetricPlaceholder.cumulativeUnit, width: 56)
                }
            } else {
                targetNumberColumn
            }
            sourceRow
            if draft.metricSource == .habit {
                habitRow
            }
            if let mismatch = aggregationMismatchText {
                mismatchRow(mismatch)
            }
        }
        .onChange(of: draft.sourceHabitId) { _, newId in
            applyBaselineFromHabit(newId)
        }
    }

    /// 数字容器：padding 12、圆角 12、surface 底、0.5 描边、minHeight 48（规格 B2）
    private func metricFieldContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(12)
            .frame(minHeight: 48)
            .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .goalJourneyText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
    }

    private func targetNumberField(placeholder: String) -> some View {
        TextField(placeholder, text: $metricTargetText)
            .goalJourneyText(.rowValue)
            .monospacedDigit()
            .foregroundStyle(Color.holoToolText)
            .focused($isFieldFocused)
            #if canImport(UIKit)
            .keyboardType(.decimalPad)
            #endif
            .onChange(of: metricTargetText) { _, newText in
                draft.metricTargetValue = Double(newText)
            }
    }

    private var baselineNumberField: some View {
        TextField(MetricPlaceholder.targetBaseline, text: $metricBaselineText)
            .goalJourneyText(.rowValue)
            .monospacedDigit()
            .foregroundStyle(Color.holoToolText)
            .focused($isFieldFocused)
            #if canImport(UIKit)
            .keyboardType(.decimalPad)
            #endif
            .onChange(of: metricBaselineText) { _, newText in
                draft.metricBaselineValue = Double(newText)
                baselineNote = nil
            }
    }

    private func unitField(placeholder: String, width: CGFloat) -> some View {
        TextField(placeholder, text: unitBinding)
            .goalJourneyText(.body)
            .foregroundStyle(Color.holoToolText)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($isFieldFocused)
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { draft.metricUnit ?? "" },
            set: { draft.metricUnit = $0.isEmpty ? nil : $0 }
        )
    }

    /// 达标型：「现在」「目标」两个独立描边框，中间独立橙色箭头（R3，对照原型 08-form-tgt）；
    /// 单位在「目标」框内右端；挂习惯自动取基线时框下显示来源注释（规格 B3）
    private var targetNumberColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricFieldContainer {
                    fieldLabel(String(localized: "现在"))
                    baselineNumberField
                }
                .frame(width: 146)
                Image(systemName: "arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(GoalJourneyStyle.action)
                metricFieldContainer {
                    fieldLabel(String(localized: "目标"))
                    targetNumberField(placeholder: MetricPlaceholder.targetTarget)
                    unitField(placeholder: MetricPlaceholder.targetUnit, width: 46)
                }
                .frame(maxWidth: .infinity)
            }
            if let baselineNote {
                Text(baselineNote)
                    .goalJourneyText(.detail)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
    }

    // MARK: - 数据来源行 + 习惯子行 + 口径警示（规格 B2/B3）

    /// 数据来源行：minHeight 44，14 次文字标签 + 15 值 + chevron；按类型收窄可选项
    private var sourceRow: some View {
        Menu {
            Picker(String(localized: "数据来源"), selection: $draft.metricSource) {
                ForEach(GoalMetricSource.selectable(for: draft.goalKind)) { source in
                    Text(source.displayName).tag(source)
                }
            }
        } label: {
            settingsRowLabel(String(localized: "数据来源"), value: draft.metricSource.displayName)
        }
        .onChange(of: draft.metricSource) { _, newSource in
            // 换源回落沿用现状：非 habit 源清空源习惯；habit 源未选时挂第一个数值习惯
            if newSource != .habit {
                draft.sourceHabitId = nil
                baselineNote = nil
            } else if draft.sourceHabitId == nil, let first = numericHabits.first {
                draft.sourceHabitId = first.id
            }
        }
    }

    private var selectedHabit: Habit? {
        guard let id = draft.sourceHabitId else { return nil }
        return numericHabits.first { $0.id == id }
    }

    /// 习惯子行与源习惯选择同构；无数值习惯时单行空态、不引导跳模块（规格 B0）
    @ViewBuilder
    private var habitRow: some View {
        if numericHabits.isEmpty {
            settingsRowLabel(String(localized: "习惯"), value: String(localized: "还没有数值型习惯"))
        } else {
            Menu {
                habitPicker
            } label: {
                settingsRowLabel(String(localized: "习惯"),
                                 value: selectedHabit.map(habitMenuTitle) ?? String(localized: "未选择"))
            }
        }
    }

    private var habitPicker: some View {
        Picker(String(localized: "习惯"), selection: $draft.sourceHabitId) {
            ForEach(numericHabits, id: \.id) { habit in
                Text(habitMenuTitle(habit)).tag(UUID?.some(habit.id))
            }
        }
    }

    private func habitMenuTitle(_ habit: Habit) -> String {
        let aggregation = habit.isCountType ? String(localized: "每天累加") : String(localized: "每天记最新值")
        return "\(habit.name) · \(aggregation)"
    }

    /// 口径错配警示（规格 B0 v2 文案，带「换「××」」动作半句）：整行可点直接弹习惯选择
    private func mismatchRow(_ text: String) -> some View {
        Menu {
            habitPicker
        } label: {
            Text(text)
                .goalJourneyText(.metadata)
                .foregroundStyle(Color.holoToolWarning)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private func settingsRowLabel(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer(minLength: 10)
            HStack(spacing: 4) {
                Text(value)
                    .goalJourneyText(.body)
                    .foregroundStyle(Color.holoToolText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .fixedSize()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 口径错配提示：累积型建议 sum 习惯、达标型建议 latest 习惯，选错只提醒不拦（v2 文案）
    private var aggregationMismatchText: String? {
        guard draft.metricSource == .habit,
              let habit = selectedHabit else { return nil }
        switch draft.goalKind {
        case .process:
            return nil
        case .cumulative:
            guard habit.isMeasureType else { return nil }
            return String(localized: "「\(habit.name)」每天只记最新值，累计会把它逐日相加 —— 换「跑步」这类每天累加的习惯")
        case .target:
            guard habit.isCountType else { return nil }
            return String(localized: "「\(habit.name)」每天累加，达标只看最新一条 —— 换「体重」这类每天记最新值的习惯")
        }
    }

    // MARK: - 期限行（规格 B0/B2：未选「不设」，选后 DatePicker compact 中文日期）

    private var deadlineRow: some View {
        HStack {
            Text("期限")
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer(minLength: 10)
            if draft.deadlineText == nil {
                Button {
                    deadlineDate = Date()
                    draft.deadlineText = GoalEditForm.formatDeadline(deadlineDate)
                } label: {
                    Text("不设")
                        .goalJourneyText(.body)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoloPressStyle())
            } else {
                DatePicker(
                    String(localized: "期限"),
                    selection: $deadlineDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
            }
        }
        .frame(minHeight: 44)
        .onChange(of: deadlineDate) { _, newDate in
            draft.deadlineText = GoalEditForm.formatDeadline(newDate)
        }
    }

    // MARK: - 习惯加载与自动基线

    private func loadHabits() {
        let repo = HabitRepository.shared
        repo.setup()
        numericHabits = repo.activeHabits.filter { $0.isNumericType }
        // 源习惯已被删除/归档时不让死 ID 原样通过校验，强制重选
        if let id = draft.sourceHabitId, !numericHabits.contains(where: { $0.id == id }) {
            draft.sourceHabitId = nil
        }
        // habit 源未选时默认挂第一个数值习惯（来源行值直接可读，不留空待办）
        if draft.metricSource == .habit, draft.sourceHabitId == nil, let first = numericHabits.first {
            draft.sourceHabitId = first.id
        }
    }

    /// 达标型换源习惯：基线自动取该习惯最新记录（现状行为保留），框下显示来源注释（规格 B3）
    private func applyBaselineFromHabit(_ habitId: UUID?) {
        guard draft.goalKind == .target,
              let habitId,
              let habit = numericHabits.first(where: { $0.id == habitId }),
              let record = latestNumericRecord(of: habit, before: Date()) else {
            baselineNote = nil
            return
        }
        metricBaselineText = GoalMetricEvaluator.formatValue(record.value)
        draft.metricBaselineValue = record.value
        baselineNote = String(localized: "取自「\(habit.name)」最新记录（\(Self.shortDayText(record.date))）")
    }

    /// 源习惯最新一条数值记录（值+日期）。走内存关系而非 HabitRepository.getLatestValue——
    /// 后者的 NSPredicate 引用了 HabitRecord 上不存在的 deletedAt 键，取值恒 nil（既有隐患，未在此修）
    private func latestNumericRecord(of habit: Habit, before date: Date) -> (value: Double, date: Date)? {
        guard let record = habit.recordsArray.first(where: { $0.valueDouble != nil && $0.date < date }),
              let value = record.valueDouble else {
            return nil
        }
        return (value, record.date)
    }

    /// 基线注释里的「11/12」短日期
    static func shortDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
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

    /// 领域赋值（S3b，规格 v3）：表单不再让用户选领域——
    /// 新建=GoalManualCreateSheet 落库前按标题认领（GoalDomain.infer(from:)）写入；
    /// 编辑=draft(from:) 保留目标原领域原样回写，绝不覆写

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

    /// 构造空 draft（手动创建模式用）；领域占位 .other，落库前按标题认领
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

    /// 禁用三态文案（规格 B0）：空标题/数字空/累积≤0/现在=目标；nil=可保存
    static func disabledHint(for draft: GoalDraft) -> String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "起个名字就能创建")
        }
        switch draft.goalKind {
        case .process:
            return nil
        case .cumulative:
            guard let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            return target > 0 ? nil : String(localized: "目标量要大于 0")
        case .target:
            guard let baseline = draft.metricBaselineValue,
                  let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            return baseline != target ? nil : String(localized: "现在和目标不能一样")
        }
    }

    /// 量化字段可保存校验：数字有效+标题非空即可保存，单位可不填（显示时省略，规格 B5）；
    /// 量化时目标值必填且 >0；达标型基线必填（允许 0，如引体向上从 0 个起步）；
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

/// 类型三选卡（规格 B2）：三等宽、圆角 12、minHeight 60、名称 14 medium + 示例 11 次文字；
/// 选中=1pt 行动色描边 + 6% 底 + 名称转行动色
private struct GoalKindCard: View {
    let title: String
    let example: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolText)
                    .lineLimit(1)
                Text(example)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                isSelected ? GoalJourneyStyle.action.opacity(0.06) : Color.holoToolSurface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? GoalJourneyStyle.action : Color.holoToolBorder,
                                  lineWidth: isSelected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(HoloPressStyle())
    }
}
