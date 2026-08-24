//
//  HoloWidgets.swift
//  HoloWidgets
//
//  iPhone / iPad 主屏幕小组件（第一批：语音启动 / 快捷控制台 / 本月收支 / 想法随机漫步）。
//  共享设计语言见 HoloWidgetChrome.swift。
//

import SwiftUI
import WidgetKit

// MARK: - Voice Launch · 呼吸光球

struct HoloVoiceLaunchWidget: Widget {
    let kind = HoloWidgetKind.voiceLaunch.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloVoiceLaunchProvider()) { entry in
            HoloVoiceLaunchView(entry: entry)
        }
        .configurationDisplayName("HoloAI 语音启动")
        .description("打开 HoloAI，并直接弹出语音输入面板。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HoloVoiceLaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<Date> {
        HoloWidgetEntry(date: Date(), value: Date(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<Date>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: Date(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<Date>>) -> Void) {
        let entry = HoloWidgetEntry(
            date: Date(),
            value: Date(),
            entitlement: HoloWidgetSnapshotStore().readEntitlement() ?? .free()
        )
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }
}

private struct HoloVoiceLaunchView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<Date>

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                Link(destination: URL(string: "holo://ai?voiceInput=true")!) {
                    if family == .systemMedium {
                        HStack(spacing: 20) {
                            voiceCore(size: 88)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("问 Holo")
                                    .font(.system(size: 23, weight: .bold))
                                    .foregroundStyle(HoloWidgetBrand.textPrimary(for: colorScheme))
                                Text("说话，是和 Holo 相处最省力的方式")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(HoloWidgetBrand.textSecondary(for: colorScheme))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(18)
                    } else {
                        VStack(spacing: 11) {
                            Spacer(minLength: 0)
                            voiceCore(size: 82)
                            VStack(spacing: 3) {
                                Text("问 Holo")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(HoloWidgetBrand.textPrimary(for: colorScheme))
                                Text("语音输入")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(HoloWidgetBrand.textSecondary(for: colorScheme))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    /// 呼吸光球：三层错相位波浪环 + 径向发光核心
    private func voiceCore(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3) { index in
                OrganicWaveShape(phase: Double(index) * 0.9)
                    .stroke(
                        index == 0
                            ? HoloWidgetBrand.primary(for: colorScheme)
                            : HoloWidgetBrand.primary(for: colorScheme).opacity(index == 1 ? 0.42 : 0.24),
                        style: StrokeStyle(
                            lineWidth: index == 0 ? 2.2 : index == 1 ? 1.1 : 0.8,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: size + CGFloat(index * 16), height: size + CGFloat(index * 13))
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            colorScheme == .dark
                                ? Color(red: 1.0, green: 0.77, blue: 0.61)
                                : HoloWidgetBrand.primaryLight,
                            HoloWidgetBrand.primary(for: colorScheme).opacity(0.35),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.36, y: 0.32),
                        startRadius: 0,
                        endRadius: size * 0.32
                    )
                )
                .frame(width: size * 0.46, height: size * 0.46)

            Circle()
                .fill(Color.white)
                .frame(width: size * 0.13, height: size * 0.13)
                .shadow(color: HoloWidgetBrand.primary(for: colorScheme).opacity(0.5), radius: 7)
                .offset(x: size * 0.03, y: size * 0.02)
        }
        .frame(width: size + 34, height: size + 30)
    }
}

// MARK: - Quick Actions · 四色入口

struct HoloQuickActionsWidget: Widget {
    let kind = HoloWidgetKind.quickActions.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloQuickActionsProvider()) { entry in
            HoloQuickActionsView(entry: entry)
        }
        .configurationDisplayName("Holo 快捷控制台")
        .description("问 Holo、记一笔、写想法、加待办。")
        .supportedFamilies([.systemMedium])
    }
}

private struct HoloQuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetQuickActionsSnapshot> {
        HoloWidgetEntry(date: Date(), value: .defaultSnapshot(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: .defaultSnapshot(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>>) -> Void) {
        let snapshot = HoloWidgetSnapshotStore().readQuickActions() ?? .defaultSnapshot()
        let entry = HoloWidgetEntry(
            date: Date(),
            value: snapshot,
            entitlement: HoloWidgetSnapshotStore().readEntitlement() ?? .free()
        )
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }
}

private struct HoloQuickActionsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("Holo 快捷")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HoloWidgetBrand.textPrimary(for: colorScheme))
                        Spacer()
                        // 三域色点：呼应四个入口的域色体系
                        HStack(spacing: 4) {
                            Circle()
                                .fill(HoloWidgetBrand.primary(for: colorScheme).opacity(0.85))
                                .frame(width: 7, height: 7)
                            Circle()
                                .fill(HoloWidgetBrand.domainGreen(for: colorScheme).opacity(0.6))
                                .frame(width: 7, height: 7)
                            Circle()
                                .fill(HoloWidgetBrand.domainPurple(for: colorScheme).opacity(0.45))
                                .frame(width: 7, height: 7)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(entry.value.actions, id: \.self) { action in
                            Link(destination: action.deepLink) {
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(action.tint(colorScheme).opacity(0.15))
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            Image(systemName: action.systemImageName)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(action.tint(colorScheme))
                                        )
                                    Text(action.title)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundStyle(HoloWidgetBrand.textPrimary(for: colorScheme))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .background(HoloWidgetBrand.card(for: colorScheme))
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(HoloWidgetBrand.hairline(for: colorScheme), lineWidth: 0.8)
                                )
                            }
                        }
                    }
                }
                .padding(16)
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }
}

private extension HoloWidgetQuickAction {
    /// 四个入口各绑一个域色：橙=AI 绿=财务 紫=想法 蓝=待办
    func tint(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .askHolo: return HoloWidgetBrand.primary(for: colorScheme)
        case .addTransaction: return HoloWidgetBrand.domainGreen(for: colorScheme)
        case .recordThought: return HoloWidgetBrand.domainPurple(for: colorScheme)
        case .addTask: return HoloWidgetBrand.domainBlue(for: colorScheme)
        }
    }
}

// MARK: - Finance · 预算罗盘

struct HoloFinanceWidget: Widget {
    let kind = HoloWidgetKind.finance.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloFinanceProvider()) { entry in
            HoloFinanceView(entry: entry)
        }
        .configurationDisplayName("本月收支")
        .description("查看本月收入、支出和预算节奏。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HoloFinanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetFinanceSnapshot> {
        HoloWidgetEntry(date: Date(), value: sampleFinance, entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetFinanceSnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: sampleFinance,
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetFinanceSnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readFinance() ?? sampleFinance) : sampleFinance
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }

    private var sampleFinance: HoloWidgetFinanceSnapshot {
        HoloWidgetFinanceSnapshot(
            monthExpense: 620,
            monthIncome: 8_500,
            monthBudget: 1_000,
            dayOfMonth: 14,
            daysInMonth: 30,
            weekExpense: (0..<7).map { offset in
                HoloWidgetDailyExpense(
                    weekdayText: ["一", "二", "三", "四", "五", "六", "今"][offset],
                    amount: [36, 58, 24, 84, 46, 62, 51][offset],
                    isToday: offset == 6
                )
            },
            topCategories: [
                HoloWidgetCategorySpend(name: "餐饮", amount: 210, colorHex: "#F97316"),
                HoloWidgetCategorySpend(name: "购物", amount: 168, colorHex: "#6366F1"),
                HoloWidgetCategorySpend(name: "交通", amount: 86, colorHex: "#10B981")
            ],
            updatedAt: Date()
        )
    }
}

private struct HoloFinanceView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetFinanceSnapshot>

    private var budgetRatio: Double? { entry.value.budgetProgress }

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                Link(destination: URL(string: "holo://finance/analysis")!) {
                    if family == .systemSmall {
                        financeSmall
                    } else if family == .systemLarge {
                        financeLarge
                    } else {
                        financeMedium
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    // MARK: Small

    private var financeSmall: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本月支出")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(textSecondary)
            Text(entry.value.monthExpense.currencyText)
                .font(.system(size: 27, weight: .heavy))
                .foregroundStyle(expenseTint)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
            if let remaining = remainingBudgetText {
                Text(remaining)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .padding(.top, 5)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text(entry.date.widgetDateText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.8))
                Spacer(minLength: 0)
                if let ratio = budgetRatio {
                    ZStack {
                        HoloWidgetRingGauge(
                            progress: ratio,
                            lineWidth: 8,
                            trackColor: trackTint,
                            progressColor: budgetTint,
                            markerFraction: entry.value.timeProgress,
                            markerFill: markerFill
                        )
                        Text("\(Int((ratio * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 56, height: 56)
                }
            }
        }
        .padding(15)
    }

    // MARK: Medium

    private var financeMedium: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(monthLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textSecondary)
                Text(entry.value.monthExpense.currencyText)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(expenseTint)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Text("收入")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Text("+\(entry.value.monthIncome.currencyText)")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(incomeTint)
                }
                .padding(.top, 8)
                Text(statusText)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(statusTint.opacity(0.14))
                    .clipShape(Capsule())
                    .padding(.top, 9)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                ZStack {
                    HoloWidgetRingGauge(
                        progress: budgetRatio ?? 0,
                        lineWidth: 8.5,
                        trackColor: trackTint,
                        progressColor: budgetTint,
                        markerFraction: budgetRatio == nil ? nil : entry.value.timeProgress,
                        markerFill: markerFill
                    )
                    if let ratio = budgetRatio {
                        Text("\(Int((ratio * 100).rounded()))%")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .minimumScaleFactor(0.7)
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "yensign.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(textSecondary)
                            Text("无预算")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(textSecondary)
                        }
                    }
                }
                .frame(width: 92, height: 92)

                if budgetRatio == nil {
                    Text("设置预算后看节奏")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(16)
    }

    // MARK: Large

    private var financeLarge: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(monthLabel) · 本月收支")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Text(entry.date.widgetDateText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    HoloWidgetRingGauge(
                        progress: budgetRatio ?? 0,
                        lineWidth: 9,
                        trackColor: trackTint,
                        progressColor: budgetTint,
                        markerFraction: budgetRatio == nil ? nil : entry.value.timeProgress,
                        markerFill: markerFill
                    )
                    if let ratio = budgetRatio {
                        VStack(spacing: 1) {
                            Text("\(Int((ratio * 100).rounded()))%")
                                .font(.system(size: 17, weight: .heavy))
                                .foregroundStyle(textPrimary)
                            Text("预算已用")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(textSecondary)
                        }
                    } else {
                        Text("无预算")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(textSecondary)
                    }
                }
                .frame(width: 108, height: 108)

                VStack(alignment: .leading, spacing: 9) {
                    financeKVRow("支出", entry.value.monthExpense.currencyText, tint: expenseTint)
                    financeKVRow("收入", "+\(entry.value.monthIncome.currencyText)", tint: incomeTint)
                    if let remaining = remainingBudgetText {
                        financeKVRow("预算剩余", remaining, tint: textPrimary)
                    }
                    financeKVRow(
                        "时间过了",
                        "\(Int((entry.value.timeProgress * 100).rounded()))%",
                        tint: textSecondary
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)

            Spacer(minLength: 0)

            if let weekExpense = entry.value.weekExpense, !weekExpense.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("本周支出节奏")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(textSecondary)
                    HStack(alignment: .bottom, spacing: 6) {
                        let maxAmount = max(weekExpense.map(\.amount).max() ?? 0, 1)
                        ForEach(Array(weekExpense.enumerated()), id: \.offset) { _, day in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(day.isToday ? budgetTint : trackTint)
                                    .frame(height: max(5, CGFloat(day.amount / maxAmount) * 40))
                                    .frame(maxWidth: .infinity)
                                Text(day.weekdayText)
                                    .font(.system(size: 8.5, weight: day.isToday ? .bold : .medium))
                                    .foregroundStyle(day.isToday ? budgetTint : textSecondary)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }

            if let categories = entry.value.topCategories, !categories.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(HoloWidgetBrand.color(fromHex: category.colorHex, colorScheme: colorScheme))
                                .frame(width: 6.5, height: 6.5)
                            Text("\(category.name) \(category.amount.currencyText)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(HoloWidgetBrand.card(for: colorScheme))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(HoloWidgetBrand.hairline(for: colorScheme), lineWidth: 0.8))
                    }
                }
                .padding(.top, 9)
            }
        }
        .padding(16)
    }

    private func financeKVRow(_ title: String, _ value: String, tint: Color) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13.5, weight: .heavy))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: Tints & 文案

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月"
        return formatter.string(from: entry.date)
    }

    private var remainingBudgetText: String? {
        guard let budget = entry.value.monthBudget, budget > 0 else { return nil }
        let remaining = max(0, budget - entry.value.monthExpense)
        return "预算 \(budget.currencyText) · 还剩 \(remaining.currencyText)"
    }

    private var statusText: String {
        switch entry.value.budgetStatus {
        case .noBudget: return "未设预算"
        case .onTrack: return "节奏正常 · 已用 \(Int(((entry.value.budgetProgress ?? 0) * 100).rounded()))%"
        case .aheadOfTime: return "花得略快 · 已用 \(Int(((entry.value.budgetProgress ?? 0) * 100).rounded()))%"
        case .overBudget: return "已超预算"
        }
    }

    private var statusTint: Color {
        switch entry.value.budgetStatus {
        case .noBudget, .onTrack:
            return HoloWidgetBrand.primary(for: colorScheme)
        case .aheadOfTime:
            return colorScheme == .dark ? HoloWidgetBrand.primaryOnDark : HoloWidgetBrand.primaryDark
        case .overBudget:
            return HoloWidgetBrand.error
        }
    }

    private var budgetTint: Color { statusTint }
    private var markerFill: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.22, blue: 0.19) : .white
    }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
    private var expenseTint: Color { HoloWidgetBrand.primary(for: colorScheme) }
    private var incomeTint: Color { HoloWidgetBrand.success(for: colorScheme) }
    private var trackTint: Color { HoloWidgetBrand.progressTrack(for: colorScheme) }
}

// MARK: - Thought Memory · 引言卡

struct HoloThoughtMemoryWidget: Widget {
    let kind = HoloWidgetKind.thoughtMemory.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloThoughtMemoryProvider()) { entry in
            HoloThoughtMemoryView(entry: entry)
        }
        .configurationDisplayName("想法随机漫步")
        .description("从过往想法里带回一条关联回忆。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct HoloThoughtMemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot> {
        HoloWidgetEntry(date: Date(), value: sampleThought, entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: sampleThought,
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readThoughtMemory() ?? sampleThought) : sampleThought
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60 * 6))))
    }

    private var sampleThought: HoloWidgetThoughtMemorySnapshot {
        HoloWidgetThoughtMemorySnapshot(
            thoughtId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(),
            tags: ["产品灵感", "自我观察"],
            excerpt: "桌面上不默认展示原文，回到 App 里再看。",
            sourceHint: "来自一次夜间记录",
            showsOriginalExcerpt: false
        )
    }
}

private struct HoloThoughtMemoryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                Link(destination: entry.value.detailDeepLink) {
                    if family == .systemLarge {
                        thoughtLarge
                    } else {
                        thoughtMedium
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    private var thoughtMedium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今天想起一条想法")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Text("✦")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(quoteTint)
            }

            quoteMark(size: 38)
                .padding(.top, 6)

            Text(entry.value.displayText)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)

            Text(entry.value.createdAt.widgetDateText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary)
                .padding(.top, 7)

            Spacer(minLength: 0)

            tagRow
        }
        .padding(16)
    }

    private var thoughtLarge: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今天想起一条想法")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Text("✦")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(quoteTint)
            }

            quoteMark(size: 56)
                .padding(.top, 10)

            Text(entry.value.displayText)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(textPrimary)
                .lineLimit(4)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)

            Text(entry.value.createdAt.widgetDateText + timeSuffix)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
                .padding(.top, 12)

            Spacer(minLength: 0)

            tagRow

            HStack {
                Text("原文已收好 · 隐私不出 App")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
                Spacer()
                Text("回到那天 →")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(quoteTint)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(HoloWidgetBrand.hairline(for: colorScheme))
                    .frame(height: 0.8)
            }
        }
        .padding(16)
    }

    /// 大号衬线引号：明信片的落款印记
    private func quoteMark(size: CGFloat) -> some View {
        Text("“")
            .font(.system(size: size, weight: .black, design: .serif))
            .foregroundStyle(quoteTint.opacity(0.45))
            .frame(height: size * 0.42, alignment: .topLeading)
            .clipped()
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            ForEach(entry.value.tags.prefix(2), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(quoteTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tagTint)
                    .clipShape(Capsule())
            }
        }
    }

    private var timeSuffix: String {
        let formatter = DateFormatter()
        formatter.dateFormat = " HH:mm"
        return formatter.string(from: entry.value.createdAt)
    }

    private var quoteTint: Color {
        colorScheme == .dark
            ? HoloWidgetBrand.purpleOnDark
            : HoloWidgetBrand.primary
    }

    private var tagTint: Color {
        colorScheme == .dark
            ? HoloWidgetBrand.purpleOnDark.opacity(0.18)
            : HoloWidgetBrand.primaryLight.opacity(0.4)
    }

    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
}
