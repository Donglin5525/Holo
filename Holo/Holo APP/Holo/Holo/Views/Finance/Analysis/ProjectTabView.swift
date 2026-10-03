//
//  ProjectTabView.swift
//  Holo
//
//  统计分析「项目」页签（2026-10-03 东林定稿五页签方案）：
//  - 列表层：按本期支出排序的项目列表（随顶部时间档变化），点行进子视图
//  - 子视图：项目头卡（全程口径）+ 本期汇总/趋势/分类构成/流水（跟随时间档）
//  - 「看项目全程」= 一键把自定义时间设为项目期间（走既有自定义时间机制）
//

import SwiftUI

extension FinanceProjectStatus {
    /// 统计页展示用状态文案（模型层不强制本地化，页签内私有口径）
    var displayText: String {
        switch self {
        case .active: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        case .archived: return String(localized: "已归档")
        }
    }
}

struct ProjectTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    @State private var selectedProject: FinanceProject?

    var body: some View {
        Group {
            if let project = selectedProject {
                ProjectInsightView(state: state, project: project) {
                    selectedProject = nil
                }
            } else {
                listView
            }
        }
        .background(Color.holoBackground)
    }

    // MARK: - 列表层

    private var listView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 页签汇总头：本期项目支出合计 + 有支出的项目数
                HStack(spacing: HoloSpacing.sm) {
                    ScopeHeadCell(
                        title: String(localized: "项目支出合计"),
                        value: totalSpentText,
                        subtitle: rangeSubtitle,
                        valueColor: .holoError
                    )
                    ScopeHeadCell(
                        title: String(localized: "有支出的项目"),
                        value: "\(spentProjectCount) 个",
                        subtitle: String(localized: "共 \(state.availableFinanceProjects.count) 个项目")
                    )
                }

                if state.availableFinanceProjects.isEmpty {
                    ScopeEmptyHintView(
                        systemIcon: "flag",
                        text: String(localized: "还没有项目，记账时可以把交易挂到项目上（如旅行、装修）")
                    )
                } else {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        Text(String(localized: "按本期支出排序"))
                            .font(.holoLabel)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)

                        let spentById = Dictionary(
                            state.financeProjectAggregations.map { ($0.project.id, $0.expense) },
                            uniquingKeysWith: { $0 + $1 }
                        )

                        ForEach(state.availableFinanceProjects, id: \.id) { project in
                            projectRow(project, spent: spentById[project.id])
                        }
                    }
                    .padding(HoloSpacing.md)
                    .holoCard()
                }
            }
            .padding(HoloSpacing.lg)
        }
    }

    private var totalSpentText: String {
        NumberFormatter.compactCurrency(
            state.financeProjectAggregations.reduce(Decimal(0)) { $0 + $1.expense }
        )
    }

    private var spentProjectCount: Int {
        state.financeProjectAggregations.filter { $0.expense > 0 }.count
    }

    private var rangeSubtitle: String {
        let (start, end) = state.currentDateRange
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(df.string(from: start)) - \(df.string(from: end.addingDays(-1)))"
    }

    private func projectRow(_ project: FinanceProject, spent: Decimal?) -> some View {
        Button {
            selectedProject = project
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Text(project.icon)
                    .font(.system(size: 17))
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(hex: project.color).opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Text(Self.metaText(project))
                        .font(.system(size: 10.5))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: HoloSpacing.sm)

                VStack(alignment: .trailing, spacing: 3) {
                    if let spent, spent > 0 {
                        Text(NumberFormatter.compactCurrency(spent))
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.holoTextPrimary)
                        if let budget = project.budgetDecimal {
                            let pct = Int(Double(truncating: (spent / budget * 100) as NSDecimalNumber))
                            Text(String(localized: "预算已用 \(pct)%"))
                                .font(.system(size: 10))
                                .foregroundColor(spent > budget ? .holoError : .holoTextSecondary)
                        }
                    } else {
                        Text(String(localized: "本期无支出"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextPlaceholder)
                    }

                    if let budget = project.budgetDecimal, budget > 0, let spent {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.holoDivider.opacity(0.4))
                                Capsule()
                                    .fill(spent > budget ? Color.holoError.opacity(0.8) : Color(hex: project.color).opacity(0.75))
                                    .frame(width: max(4, geo.size.width * min(max(Double(truncating: (spent / budget) as NSDecimalNumber), 0), 1)))
                            }
                        }
                        .frame(width: 76, height: 5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 行内期间/状态描述：项目期间 + 状态；无期间信息只显示状态。
    /// `includesStatus: false` 给项目头卡用——状态已由右上胶囊承担，副标题再带一遍「进行中」是重复
    static func metaText(_ project: FinanceProject, includesStatus: Bool = true) -> String {
        var parts: [String] = []
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("Md")
        if let start = project.startDate {
            var text = df.string(from: start)
            if let end = project.endDate {
                text += " – " + df.string(from: end)
            } else {
                text += " – " + String(localized: "至今")
            }
            parts.append(text)
        }
        if includesStatus {
            parts.append(project.statusEnum.displayText)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 项目子视图

private struct ProjectInsightView: View {
    @ObservedObject var state: FinanceAnalysisState
    let project: FinanceProject
    var onBack: () -> Void

    @State private var insight: FinanceAnalysisState.ScopeInsight?

    /// 全程口径头卡数据（不随时间档变化）
    @State private var totalSpent: Decimal = 0
    @State private var spanDays: Int?

    /// 重载键：项目 + 当前时间范围（含排他上界），任一变化即重取
    private var reloadKey: String {
        let (start, end) = state.currentDateRange
        return "\(project.id.uuidString)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                headerCard

                spanQuickBar

                if let insight {
                    summaryCard(insight)
                    TrendChartView(dataPoints: insight.chartPoints, showsBalanceLine: false)

                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        Text(String(localized: "分类构成"))
                            .font(.holoLabel)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)
                        ScopeCategoryBars(aggregations: insight.expenseAggregations)
                    }
                    .padding(HoloSpacing.md)
                    .holoCard()

                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text(String(localized: "交易流水"))
                            .font(.holoLabel)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)

                        if insight.transactions.isEmpty {
                            Text(String(localized: "该时间范围内无交易"))
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, HoloSpacing.md)
                        } else {
                            ForEach(insight.transactions.suffix(30).reversed(), id: \.id) { txn in
                                ScopeTxnRow(transaction: txn)
                            }
                        }
                    }
                    .padding(HoloSpacing.md)
                    .holoCard()
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
                        .padding(.vertical, HoloSpacing.xl)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .task(id: reloadKey) {
            await load()
        }
    }

    private func load() async {
        // 头卡全程口径（一次性）
        if totalSpent == 0 {
            totalSpent = FinanceProjectRepository.shared.totalExpense(forProject: project.id)
            if let span = FinanceProjectRepository.shared.projectSpan(of: project) {
                let days = Calendar.current.dateComponents([.day], from: span.start, to: span.end).day ?? 0
                spanDays = max(days, 1)
            }
        }
        // 本期数据（随时间档）
        insight = await state.loadScopeInsight(
            scope: StatisticsScope(accountId: nil, financeProjectId: project.id)
        )
    }

    // MARK: 头卡（全程口径）

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Text(project.icon)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(headerMetaText)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.85))
                }

                Spacer(minLength: 4)

                Text(project.statusEnum.displayText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.25)))
            }

            HStack(spacing: 0) {
                headerStat(title: String(localized: "项目总支出（全程）"), value: NumberFormatter.compactCurrency(totalSpent))

                if let budget = project.budgetDecimal {
                    Divider().frame(height: 32).overlay(Color.white.opacity(0.3))
                    headerStat(
                        title: String(localized: "预算 \(NumberFormatter.compactCurrency(budget))"),
                        value: totalSpent > budget
                            ? String(localized: "超支 \(NumberFormatter.compactCurrency(totalSpent - budget))")
                            : String(localized: "剩 \(NumberFormatter.compactCurrency(budget - totalSpent))")
                    )
                }

                if let spanDays, totalSpent > 0 {
                    Divider().frame(height: 32).overlay(Color.white.opacity(0.3))
                    headerStat(title: String(localized: "全程日均"), value: NumberFormatter.compactCurrency(totalSpent / Decimal(spanDays)))
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: project.color), Color(hex: project.color).opacity(0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
    }

    /// 头卡副标题：期间 + 天数；状态由右上胶囊承担，不进副标题
    private var headerMetaText: String {
        var parts: [String] = []
        let span = ProjectTabView.metaText(project, includesStatus: false)
        if !span.isEmpty { parts.append(span) }
        if let spanDays { parts.append("\(spanDays) 天") }
        return parts.joined(separator: " · ")
    }

    private func headerStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    // MARK: 「看项目全程」快捷条

    /// 当前筛选范围已等于项目全程时快捷条没有意义（按钮点了不动作，范围顶部胶囊也在显示），
    /// 整条隐藏；用户切到别的档位（本月等）再出现，提供一键回全程
    @ViewBuilder
    private var spanQuickBar: some View {
        if let span = FinanceProjectRepository.shared.projectSpan(of: project),
           state.currentDateRange.start != span.start || state.currentDateRange.end != span.end {
            HStack(spacing: HoloSpacing.sm) {
                Text(String(localized: "当前范围：\(TimeRange.pillLabel(timeRange: state.timeRange, start: state.currentDateRange.start, end: state.currentDateRange.end))"))
                    .font(.system(size: 11.5))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)

                Spacer(minLength: HoloSpacing.sm)

                Button {
                    state.applyProjectSpan(project)
                } label: {
                    Text(String(localized: "看项目全程"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoPrimary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .strokeBorder(Color.holoPrimary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            )
        }
    }

    // MARK: 本期汇总

    private func summaryCard(_ insight: FinanceAnalysisState.ScopeInsight) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(String(localized: "本期汇总"))
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            HStack(spacing: 0) {
                ScopeHeadCell(title: String(localized: "支出"), value: insight.summary.formattedExpense, subtitle: "\(insight.summary.transactionCount) 笔", valueColor: .holoError)
                ScopeHeadCell(title: String(localized: "收入"), value: insight.summary.formattedIncome, subtitle: "")
                ScopeHeadCell(title: String(localized: "日均"), value: NumberFormatter.compactCurrency(insight.summary.averageDailyExpense), subtitle: "")
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }
}

// MARK: - 页签共用小组件

/// 页签汇总头/汇总三格共用的「标题+数值+副标题」格
struct ScopeHeadCell: View {
    let title: String
    let value: String
    var subtitle: String = ""
    var valueColor: Color = .holoTextPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // 副标题行恒占位（空则用空格撑住行高）：三格并列时内容等高，
            // 否则带「29 笔」的格子内容整体居中上浮，三格金额基线错位
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 9.5))
                .foregroundColor(.holoTextPlaceholder)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.holoCardBackground)
                .shadow(color: Color.black.opacity(0.04), radius: 4, y: 1)
        )
    }
}

/// 页签空态引导（无项目等）：SF Symbol 图标（emoji 在部分字体环境渲染为兜底字形，不采用）
struct ScopeEmptyHintView: View {
    let systemIcon: String
    let text: String

    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: systemIcon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }
}
