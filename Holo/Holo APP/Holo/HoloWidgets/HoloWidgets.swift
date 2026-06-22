//
//  HoloWidgets.swift
//  HoloWidgets
//
//  iPhone / iPad 主屏幕小组件。
//

import SwiftUI
import WidgetKit

// MARK: - Shared

private enum HoloWidgetBrand {
    static let background = Color(red: 0.992, green: 0.988, blue: 0.973)
    static let card = Color.white.opacity(0.72)
    static let primary = Color(red: 244/255, green: 109/255, blue: 56/255)
    static let primaryLight = Color(red: 254/255, green: 215/255, blue: 170/255)
    static let primaryDark = Color(red: 234/255, green: 88/255, blue: 12/255)
    static let textPrimary = Color(red: 0.2, green: 0.2, blue: 0.2)
    static let textSecondary = Color(red: 0.576, green: 0.576, blue: 0.576)
    static let success = Color(red: 34/255, green: 197/255, blue: 94/255)
    static let error = Color(red: 239/255, green: 68/255, blue: 68/255)
}

private struct HoloWidgetEntry<T>: TimelineEntry {
    let date: Date
    let value: T
}

private extension View {
    func holoWidgetBackground() -> some View {
        containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    HoloWidgetBrand.background,
                    HoloWidgetBrand.primaryLight.opacity(0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private extension Double {
    var currencyText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "¥"
        formatter.maximumFractionDigits = self.rounded() == self ? 0 : 2
        return formatter.string(from: NSNumber(value: self)) ?? "¥0"
    }
}

private extension Date {
    var widgetDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: self)
    }
}

// MARK: - Voice Launch

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
        HoloWidgetEntry(date: Date(), value: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<Date>) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<Date>>) -> Void) {
        let entry = HoloWidgetEntry(date: Date(), value: Date())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }
}

private struct HoloVoiceLaunchView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HoloWidgetEntry<Date>

    var body: some View {
        Link(destination: URL(string: "holo://ai?voiceInput=true")!) {
            if family == .systemMedium {
                HStack(spacing: 18) {
                    voiceCore(size: 86)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("问 Holo")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(HoloWidgetBrand.textPrimary)
                        Text("打开语音输入")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HoloWidgetBrand.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
            } else {
                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    voiceCore(size: 84)
                    VStack(spacing: 3) {
                        Text("问 Holo")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(HoloWidgetBrand.textPrimary)
                        Text("语音输入")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HoloWidgetBrand.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
        .holoWidgetBackground()
    }

    private func voiceCore(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3) { index in
                OrganicWaveShape(phase: Double(index) * 0.9)
                    .stroke(
                        index == 0 ? HoloWidgetBrand.primary : HoloWidgetBrand.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: index == 0 ? 2.4 : 1.2, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: size + CGFloat(index * 18), height: size + CGFloat(index * 14))
                    .opacity(index == 2 ? 0.55 : 1)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            HoloWidgetBrand.primaryLight,
                            HoloWidgetBrand.primary.opacity(0.35),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.34
                    )
                )
                .frame(width: size * 0.48, height: size * 0.48)

            Circle()
                .fill(Color.white)
                .frame(width: size * 0.13, height: size * 0.13)
                .shadow(color: HoloWidgetBrand.primary.opacity(0.45), radius: 8)
        }
        .frame(width: size + 34, height: size + 34)
    }
}

private struct OrganicWaveShape: Shape {
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 120

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let angle = t * 2 * .pi
            let wave = sin(angle * 4 + phase) * 0.08 + cos(angle * 3 - phase) * 0.055
            let radiusX = rect.width * 0.38 * (1 + wave)
            let radiusY = rect.height * 0.36 * (1 - wave * 0.65)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle) * radiusX),
                y: center.y + CGFloat(sin(angle) * radiusY)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Quick Actions

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
        HoloWidgetEntry(date: Date(), value: .defaultSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>>) -> Void) {
        let snapshot = HoloWidgetSnapshotStore().readQuickActions() ?? .defaultSnapshot()
        let entry = HoloWidgetEntry(date: Date(), value: snapshot)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }
}

private struct HoloQuickActionsView: View {
    let entry: HoloWidgetEntry<HoloWidgetQuickActionsSnapshot>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Holo 快捷")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HoloWidgetBrand.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(entry.value.actions, id: \.self) { action in
                    Link(destination: action.deepLink) {
                        HStack(spacing: 8) {
                            Image(systemName: action.systemImageName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(HoloWidgetBrand.primary)
                                .frame(width: 24, height: 24)
                            Text(action.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(HoloWidgetBrand.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(HoloWidgetBrand.card)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .holoWidgetBackground()
    }
}

// MARK: - Finance

struct HoloFinanceWidget: Widget {
    let kind = HoloWidgetKind.finance.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloFinanceProvider()) { entry in
            HoloFinanceView(entry: entry)
        }
        .configurationDisplayName("今日收支")
        .description("查看今日收入、支出和本月预算节奏。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HoloFinanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetFinanceSnapshot> {
        HoloWidgetEntry(date: Date(), value: sampleFinance)
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetFinanceSnapshot>) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetFinanceSnapshot>>) -> Void) {
        let snapshot = HoloWidgetSnapshotStore().readFinance() ?? sampleFinance
        let entry = HoloWidgetEntry(date: Date(), value: snapshot)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }

    private var sampleFinance: HoloWidgetFinanceSnapshot {
        HoloWidgetFinanceSnapshot(
            todayExpense: 128.5,
            todayIncome: 0,
            monthExpense: 620,
            monthBudget: 1_000,
            dayOfMonth: 14,
            daysInMonth: 30,
            updatedAt: Date()
        )
    }
}

private struct HoloFinanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HoloWidgetEntry<HoloWidgetFinanceSnapshot>

    var body: some View {
        Link(destination: URL(string: "holo://finance/analysis")!) {
            if family == .systemSmall {
                financeSmall
            } else {
                financeMedium
            }
        }
        .holoWidgetBackground()
    }

    private var financeSmall: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日支出")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HoloWidgetBrand.textSecondary)
            Text(entry.value.todayExpense.currencyText)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(HoloWidgetBrand.textPrimary)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
            budgetProgress
        }
        .padding(16)
    }

    private var financeMedium: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日收支")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HoloWidgetBrand.textPrimary)
                Spacer()
                Text("本地")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HoloWidgetBrand.textSecondary)
            }

            HStack(spacing: 18) {
                financeMetric("支出", entry.value.todayExpense.currencyText, tint: HoloWidgetBrand.primary)
                financeMetric("收入", entry.value.todayIncome.currencyText, tint: HoloWidgetBrand.success)
            }

            Spacer(minLength: 0)
            budgetProgress
        }
        .padding(16)
    }

    private func financeMetric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HoloWidgetBrand.textSecondary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var budgetProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = entry.value.budgetProgress {
                Text("预算已用 \(Int(progress * 100))% · 时间过了 \(Int(entry.value.timeProgress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HoloWidgetBrand.textSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HoloWidgetBrand.primaryLight.opacity(0.45))
                        Capsule()
                            .fill(budgetTint)
                            .frame(width: geo.size.width * min(progress, 1))
                    }
                }
                .frame(height: 7)
            } else {
                Text("本月支出 \(entry.value.monthExpense.currencyText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HoloWidgetBrand.textSecondary)
            }
        }
    }

    private var budgetTint: Color {
        switch entry.value.budgetStatus {
        case .noBudget, .onTrack:
            return HoloWidgetBrand.primary
        case .aheadOfTime:
            return HoloWidgetBrand.primaryDark
        case .overBudget:
            return HoloWidgetBrand.error
        }
    }
}

// MARK: - Thought Memory

struct HoloThoughtMemoryWidget: Widget {
    let kind = HoloWidgetKind.thoughtMemory.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloThoughtMemoryProvider()) { entry in
            HoloThoughtMemoryView(entry: entry)
        }
        .configurationDisplayName("想法随机漫步")
        .description("从过往想法里带回一条关联回忆。")
        .supportedFamilies([.systemMedium])
    }
}

private struct HoloThoughtMemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot> {
        HoloWidgetEntry(date: Date(), value: sampleThought)
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>>) -> Void) {
        let snapshot = HoloWidgetSnapshotStore().readThoughtMemory() ?? sampleThought
        let entry = HoloWidgetEntry(date: Date(), value: snapshot)
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
    let entry: HoloWidgetEntry<HoloWidgetThoughtMemorySnapshot>

    var body: some View {
        Link(destination: entry.value.detailDeepLink) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("今天想起一条想法")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HoloWidgetBrand.textPrimary)
                    Spacer()
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HoloWidgetBrand.primary)
                }

                Text(entry.value.createdAt.widgetDateText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HoloWidgetBrand.textSecondary)

                Text(entry.value.displayText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HoloWidgetBrand.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    ForEach(entry.value.tags.prefix(2), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HoloWidgetBrand.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(HoloWidgetBrand.primaryLight.opacity(0.38))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(16)
        }
        .holoWidgetBackground()
    }
}

