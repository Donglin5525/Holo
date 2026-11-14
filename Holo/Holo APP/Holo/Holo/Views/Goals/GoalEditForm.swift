//
//  GoalEditForm.swift
//  Holo
//
//  目标创建/编辑表单（2026-11-13 目标界面减法重设计 S2+S3，规格 §四；
//  2026-11-14 真机试用七条可用性修复：单行大输入、卡片化、统一单行选择行、
//  账本范围选择、账本源单位固定 ¥、过程型说人话文案）
//  一句话大输入 → 类型三选卡 →（数字提示行，条件）→ 条件数字区（按类型浮现）→ 期限行。
//  只操作 GoalDraft（值类型），保存动作由调用方决定：
//    - 创建模式：调 GoalRepository.saveDraft
//    - 编辑模式：调 GoalRepository.updateFields
//  说明/期望结果/动机/图标/AI 上下文五字段已移至 GoalSettingsSheet（S5 接入详情页设置）。
//

import SwiftUI
import CoreData

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

    /// 达标型基线自动取值时「现在」框下方的来源注释（习惯=最新记录 / 账本=当前余额，M/d）
    @State private var baselineNote: String?

    /// habit 源可挂的数值习惯（活跃未归档；onAppear 加载一次，避免 body 里反复 fetch）
    @State private var numericHabits: [Habit] = []

    /// ledger 源可选的账户（活跃未归档；onAppear 加载一次，七条 §5）
    @State private var ledgerAccounts: [Account] = []

    /// decimalPad 无收起键：键盘附件「完成」统一收起（规格 B3 / 七条 §3）
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
                .padding(.top, 16)

            typeCards
                .padding(.top, 8)

            // 过程型说人话（七条 §7）：选中时三卡下方解释要干什么
            if draft.goalKind == .process {
                Text("不用填数字——创建后到详情页拆成任务和习惯")
                    .goalJourneyText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            if let hintNumber = activeHintNumber {
                cumulativeHintRow(hintNumber)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            if draft.isQuantitative {
                metricSection
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            deadlineRow
                .padding(.top, 16)
        }
        .padding(.top, 20)
        .animation(.easeInOut(duration: 0.2), value: draft.isQuantitative)
        .animation(.easeInOut(duration: 0.2), value: activeHintNumber)
        .animation(.easeInOut(duration: 0.2), value: draft.goalKind)
        .onAppear {
            loadHabits()
            loadAccounts()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { isFieldFocused = false }
            }
        }
    }

    // MARK: - 大输入（七条 §1/§2：单行 TextField 收回车；surface 卡片化与数字框同族）

    private var bigInput: some View {
        TextField(
            String(localized: "想做成什么？"),
            text: $draft.title,
            prompt: Text(String(localized: "想做成什么？")).foregroundStyle(Color.holoTextPlaceholder)
        )
        .goalJourneyText(.heading)
        .tracking(-0.3)
        .foregroundStyle(Color.holoToolText)
        .lineLimit(1)
        .submitLabel(.done)
        .onSubmit { isFieldFocused = false }
        .focused($isFieldFocused)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 56, alignment: .center)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
    }

    // MARK: - 类型三选卡（规格 B2：三等宽间距 8、圆角 12、minHeight 60）

    private var typeCards: some View {
        HStack(spacing: 8) {
            GoalKindCard(title: String(localized: "过程型"), example: String(localized: "拆成任务和习惯"),
                         isSelected: draft.goalKind == .process) { selectKind(.process) }
            GoalKindCard(title: String(localized: "累积型"), example: String(localized: "如 跑满 300km"),
                         isSelected: draft.goalKind == .cumulative) { selectKind(.cumulative) }
            GoalKindCard(title: String(localized: "达标型"), example: String(localized: "如 减到 70kg"),
                         isSelected: draft.goalKind == .target) { selectKind(.target) }
        }
    }

    /// 切换类型永不改写用户已输入的标题与数字（规格 B3 硬规则）；
    /// 数据回落沿用现状：来源不在可选集回落手动，非 habit 源清空源习惯；
    /// ledger 源的类型换挡后账本范围可能不再合法（如累积→达标），重置为该类型默认（七条 §5）
    private func selectKind(_ kind: GoalKind) {
        draft.goalKind = kind
        if !GoalMetricSource.selectable(for: kind).contains(draft.metricSource) {
            draft.metricSource = .manual
        }
        if draft.metricSource != .habit {
            draft.sourceHabitId = nil
        }
        if draft.metricSource == .ledger {
            normalizeLedgerScope()
        }
        if kind != .target {
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
    /// 数字同时写 draft（与挂习惯自动基线同构）——类型切换后数字框才随条件区插入层级，
    /// 只改文本 State 的话 onChange 观察不到这次写入，保存校验会拿不到值；
    /// 顺带做单位微型映射（公里→km、公斤/kg→kg、元/块→¥、本/次/页原样），
    /// 命中且单位为空才填，不命中留空（R5）；切换后类型非过程型，提示行随条件消失
    private func applyCumulativeHint(_ number: Int) {
        selectKind(.cumulative)
        if metricTargetText.isEmpty {
            let text = GoalMetricEvaluator.formatValue(Double(number))
            metricTargetText = text
            draft.metricTargetValue = Double(number)
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

    private var isLedgerSource: Bool { draft.metricSource == .ledger }

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.goalKind == .cumulative {
                metricFieldContainer {
                    fieldLabel(String(localized: "目标"))
                    if isLedgerSource {
                        currencyMark
                        targetNumberField(placeholder: MetricPlaceholder.cumulativeTarget)
                    } else {
                        targetNumberField(placeholder: MetricPlaceholder.cumulativeTarget)
                        unitField(placeholder: MetricPlaceholder.cumulativeUnit, width: 56)
                    }
                }
            } else {
                targetNumberColumn
            }
            sourceRow
            if draft.metricSource == .habit {
                habitRow
            }
            if isLedgerSource {
                ledgerAccountRow
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

    /// 账本源数字框内左端 ¥（七条 §6）：单位固定为 ¥，不暴露单位输入
    private var currencyMark: some View {
        Text("¥")
            .goalJourneyText(.body)
            .foregroundStyle(Color.holoToolTextSecondary)
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
    /// 单位在「目标」框内右端；账本源两框左端 ¥、不露出单位输入（七条 §6）；
    /// 挂习惯/选账户自动取基线时框下显示来源注释（规格 B3 / 七条 §5）
    private var targetNumberColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricFieldContainer {
                    fieldLabel(String(localized: "现在"))
                    if isLedgerSource { currencyMark }
                    baselineNumberField
                }
                .frame(width: 146)
                Image(systemName: "arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(GoalJourneyStyle.action)
                metricFieldContainer {
                    fieldLabel(String(localized: "目标"))
                    if isLedgerSource { currencyMark }
                    targetNumberField(placeholder: MetricPlaceholder.targetTarget)
                    if !isLedgerSource {
                        unitField(placeholder: MetricPlaceholder.targetUnit, width: 46)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if let baselineNote {
                Text(baselineNote)
                    .goalJourneyText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
    }

    // MARK: - 数据来源行 + 习惯/账本子行 + 口径警示（规格 B2/B3；七条 §4/§5）

    /// 数据来源行：统一行组件（高 48、单行禁换行）；按类型收窄可选项
    private var sourceRow: some View {
        Menu {
            Picker(String(localized: "数据来源"), selection: $draft.metricSource) {
                ForEach(GoalMetricSource.selectable(for: draft.goalKind)) { source in
                    Text(source.displayName).tag(source)
                }
            }
        } label: {
            pickerRow(label: String(localized: "数据来源"), value: draft.metricSource.displayName)
        }
        .onChange(of: draft.metricSource) { _, newSource in
            applySourceChange(newSource)
        }
    }

    /// 换源回落（沿用现状 + 七条 §5/§6）：非 habit 清源习惯；
    /// ledger 固定单位 ¥ 并对齐账本范围、达标型自动取账户余额当基线；
    /// habit 源未选时挂第一个数值习惯（基线经 sourceHabitId onChange 自动取）
    private func applySourceChange(_ newSource: GoalMetricSource) {
        switch newSource {
        case .habit:
            if draft.sourceHabitId == nil, let first = numericHabits.first {
                draft.sourceHabitId = first.id
            }
        case .ledger:
            draft.sourceHabitId = nil
            draft.metricUnit = "¥"
            normalizeLedgerScope()
            applyBaselineFromAccount(draft.ledgerScope)
        case .manual:
            draft.sourceHabitId = nil
            baselineNote = nil
        }
    }

    /// 统一单行选择行（七条 §4）：高 48、标签 14 次文字固定左侧、值 15 主文字 +
    /// chevron.right 12 次文字右对齐，lineLimit(1)+minimumScaleFactor(0.8) 禁换行；
    /// 外层 VStack leading 对齐保证标签左缘与数字卡左缘同竖线
    private func pickerRow(label: String, value: String, icon: String = "chevron.right") -> some View {
        HStack(spacing: 10) {
            Text(label)
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            pickerRowValue(value, icon: icon)
        }
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    /// 行右端值+chevron；期限行已设日期时右侧换 DatePicker，值区不复用（见 deadlineRow）
    private func pickerRowValue(_ value: String, icon: String = "chevron.right") -> some View {
        HStack(spacing: 4) {
            Text(value)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .fixedSize()
    }

    private var selectedHabit: Habit? {
        guard let id = draft.sourceHabitId else { return nil }
        return numericHabits.first { $0.id == id }
    }

    /// 习惯子行与源习惯选择同构；无数值习惯时单行空态、不引导跳模块（规格 B0）
    @ViewBuilder
    private var habitRow: some View {
        if numericHabits.isEmpty {
            pickerRow(label: String(localized: "习惯"), value: String(localized: "还没有数值型习惯"))
        } else {
            Menu {
                habitPicker
            } label: {
                pickerRow(label: String(localized: "习惯"),
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

    // MARK: - 账本子行（七条 §5：暴露账本范围，链路已有只缺 UI）

    /// 账本子行：累积型=「全部账本」（默认）+ 各活跃账户净结余增加；
    /// 达标型=各活跃账户余额（必选，默认第一个）；无账户时空态禁用、不引导跳模块
    @ViewBuilder
    private var ledgerAccountRow: some View {
        if ledgerAccounts.isEmpty {
            pickerRow(label: String(localized: "账本"), value: String(localized: "还没有账户"))
        } else {
            Menu {
                Picker(String(localized: "账本"), selection: ledgerScopeSelection) {
                    if draft.goalKind == .cumulative {
                        Text(String(localized: "全部账本"))
                            .tag(GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil))
                    }
                    ForEach(ledgerAccounts, id: \.id) { account in
                        Text(account.name).tag(GoalLedgerScopePayload(
                            kind: draft.goalKind == .cumulative ? .accountDelta : .accountBalance,
                            accountID: account.id
                        ))
                    }
                }
            } label: {
                pickerRow(label: String(localized: "账本"), value: ledgerScopeDisplayValue)
            }
        }
    }

    /// 账本范围选择：选账户即写 draft.ledgerScope；达标型顺带刷新「现在」=该账户当前余额
    private var ledgerScopeSelection: Binding<GoalLedgerScopePayload> {
        Binding(
            get: {
                draft.ledgerScope ?? GoalLedgerScopePayload(
                    kind: draft.goalKind == .cumulative ? .wholeLedgerDelta : .accountBalance,
                    accountID: draft.goalKind == .cumulative ? nil : ledgerAccounts.first?.id
                )
            },
            set: { newValue in
                draft.ledgerScope = newValue
                applyBaselineFromAccount(newValue)
            }
        )
    }

    /// 账本子行的值文案：全部账本 / 账户名 / 未选择
    private var ledgerScopeDisplayValue: String {
        switch draft.ledgerScope?.kind {
        case .wholeLedgerDelta:
            return String(localized: "全部账本")
        case .accountDelta, .accountBalance:
            if let id = draft.ledgerScope?.accountID,
               let account = ledgerAccounts.first(where: { $0.id == id }) {
                return account.name
            }
            return String(localized: "未选择")
        case nil:
            return draft.goalKind == .cumulative ? String(localized: "全部账本") : String(localized: "未选择")
        }
    }

    /// 账本范围与目标类型/账户列表对齐：类型换挡或账户失效（删除/归档）后重置默认；
    /// 达标型无账户时维持无效值 → 子行走「还没有账户」空态 + 保存拦截
    private func normalizeLedgerScope() {
        let scope = draft.ledgerScope
        let valid: Bool
        switch scope?.kind {
        case .some(.wholeLedgerDelta): valid = draft.goalKind == .cumulative
        case .some(.accountDelta): valid = draft.goalKind == .cumulative && accountExists(scope?.accountID)
        case .some(.accountBalance): valid = draft.goalKind == .target && accountExists(scope?.accountID)
        case nil: valid = false
        }
        guard !valid else { return }
        if draft.goalKind == .target, let first = ledgerAccounts.first {
            draft.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: first.id)
        } else {
            draft.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        }
    }

    private func accountExists(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return ledgerAccounts.contains { $0.id == id }
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

    // MARK: - 期限行（规格 B0/B2；七条 §4 统一行组件：未选=「不设」，选后 DatePicker）

    private var deadlineRow: some View {
        HStack(spacing: 10) {
            Text("期限")
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            if draft.deadlineText == nil {
                Menu {
                    Button(String(localized: "设个期限")) {
                        deadlineDate = Date()
                    }
                } label: {
                    pickerRowValue(String(localized: "不设"))
                }
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
        .frame(height: 48)
        .onChange(of: deadlineDate) { _, newDate in
            draft.deadlineText = GoalEditForm.formatDeadline(newDate)
        }
    }

    // MARK: - 习惯/账户加载与自动基线

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

    /// 账户列表（活跃未归档，谓词与 FinanceRepository.getAccounts 同源）；
    /// 编辑预填时范围指向的账户已删/归档 → normalize 重置（七条 §5）
    private func loadAccounts() {
        ledgerAccounts = FinanceRepository.shared.getAccounts()
        if isLedgerSource {
            draft.metricUnit = "¥"
            normalizeLedgerScope()
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

    /// 达标型+账本：选账户后「现在」自动取该账户当前余额，切换账户即刷新；
    /// 框下注释「取自「××」当前余额（M/d）」（七条 §5，对齐挂习惯行为）
    private func applyBaselineFromAccount(_ scope: GoalLedgerScopePayload?) {
        guard draft.goalKind == .target,
              let id = scope?.accountID,
              let account = ledgerAccounts.first(where: { $0.id == id }),
              case .observed(let balance, let asOf, _, _) = FinanceRepository.shared.accountBalanceObservation(accountId: id, before: Date()) else {
            baselineNote = nil
            return
        }
        let value = NSDecimalNumber(decimal: balance).doubleValue
        metricBaselineText = GoalMetricEvaluator.formatValue(value)
        draft.metricBaselineValue = value
        baselineNote = String(localized: "取自「\(account.name)」当前余额（\(Self.shortDayText(asOf))）")
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

    /// 编辑预填的账本范围：Goal.ledgerScopePayload（JSON）为真源；
    /// 共创旧目标该字段只存 kind 原始值（无账户 ID）时回落最新计划版本 payload 的完整范围
    static func prefilledLedgerScope(of goal: Goal) -> GoalLedgerScopePayload? {
        if let payload = goal.ledgerScopePayload { return payload }
        guard let context = goal.managedObjectContext,
              let row = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context) else {
            return nil
        }
        return row.planPayloadV2?.resultSource?.ledgerScope
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
            sourceHabitId: goal.sourceHabitId,
            ledgerScope: goal.metricSourceEnum == .ledger ? prefilledLedgerScope(of: goal) : nil
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

    /// 禁用三态文案（规格 B0）：空标题/数字空/累积≤0/现在=目标/账本无可用账户；nil=可保存
    static func disabledHint(for draft: GoalDraft) -> String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "起个名字就能创建")
        }
        switch draft.goalKind {
        case .process:
            return nil
        case .cumulative:
            guard let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            guard target > 0 else { return String(localized: "目标量要大于 0") }
        case .target:
            guard let baseline = draft.metricBaselineValue,
                  let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            guard baseline != target else { return String(localized: "现在和目标不能一样") }
        }
        if draft.metricSource == .ledger, !hasValidLedgerScope(in: draft) {
            return String(localized: "还没有可用的账本账户")
        }
        return nil
    }

    /// ledger 源的账本范围合法性（七条 §5）：类型与范围 kind 匹配，
    /// 账户口径必须带账户 ID（无账户时表单走空态、保存拦截）
    static func hasValidLedgerScope(in draft: GoalDraft) -> Bool {
        guard draft.metricSource == .ledger, let scope = draft.ledgerScope else { return false }
        switch scope.kind {
        case .wholeLedgerDelta:
            return draft.goalKind == .cumulative
        case .accountDelta:
            return draft.goalKind == .cumulative && scope.accountID != nil
        case .accountBalance:
            return draft.goalKind == .target && scope.accountID != nil
        }
    }

    /// 量化字段可保存校验：数字有效+标题非空即可保存，单位可不填（显示时省略，规格 B5）；
    /// 量化时目标值必填且 >0；达标型基线必填（允许 0，如引体向上从 0 个起步）；
    /// habit 源必选一个源习惯；ledger 源账本范围必须合法
    static func metricFieldsValid(in draft: GoalDraft) -> Bool {
        guard draft.isQuantitative else { return true }
        guard let target = draft.metricTargetValue, target > 0 else { return false }
        if draft.goalKind == .target {
            guard let baseline = draft.metricBaselineValue, baseline != target else { return false }
        }
        if draft.metricSource == .habit, draft.sourceHabitId == nil {
            return false
        }
        if draft.metricSource == .ledger {
            return hasValidLedgerScope(in: draft)
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
