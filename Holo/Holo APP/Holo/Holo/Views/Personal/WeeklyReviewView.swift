//
//  WeeklyReviewView.swift
//  Holo
//
//  每周回顾页（2026-11-07 东林拍板 · 融合版原型 1:1 落实）
//
//  - 进行中的本周，随时可看：主角卡 = 记账·想法·任务合计，四项足迹 + 同期比涨跌
//  - 识图并入记账（不再单列）；首周无对比，主角卡换首周条幅
//  - 本周零记录 = 召唤页：不设行动按钮（用户此刻不知道该记财务还是想法），文案柔性引导
//  - 深浅色全部走 colorset token；埋点 weekly_review_viewed（weekStart = 周一 yyyy-MM-dd）
//

import SwiftUI

struct WeeklyReviewView: View {
    @State private var snapshot: WeeklyReviewSnapshot?
    @State private var hasAppeared = false

    private let aggregator: WeeklyReviewAggregator
    private let calendar: Calendar

    init(aggregator: WeeklyReviewAggregator = .shared, calendar: Calendar = .current) {
        self.aggregator = aggregator
        self.calendar = calendar
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            if let snapshot {
                if snapshot.current.hasAnyActivity {
                    reviewContent(snapshot)
                } else {
                    emptyState(snapshot)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            }
        }
        // 纵向 ScrollView 默认按子视图收缩宽度：加载态仅含 20pt 宽 ProgressView 时，
        // ScrollView 自身只有 20pt 宽，挂在其上的 .background(Color.holoPaper) 会画成
        // 屏幕正中的一条竖带（2026-11-26 根因定谳，之前只补了 containerBackground 未修宽，
        // 底色换成 holoPaper 后再次露出）。此处撑满容器 + 导航容器底色统一 holoPaper 彻底根治。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoPaper.ignoresSafeArea())
        .modifier(WeekReviewNavContainerBackground())
        .navigationTitle(String(localized: "每周回顾"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard snapshot == nil else { return }
            let now = Date()
            // 先同步出四项足迹快照，首帧直出内容、不等异步知识库查询
            let base = aggregator.makeSnapshot(now: now, calendar: calendar)
            snapshot = base
            withAnimation(HoloAnimation.smooth) {
                hasAppeared = true
            }
            HoloProductAnalytics.shared.track(
                .weeklyReviewViewed,
                ["weekStart": Self.analyticsDayKey(base.weekStart, calendar: calendar)]
            )
            let insights = await Self.confirmedInsightsThisWeek(now: now, calendar: calendar)
            if !insights.isEmpty {
                snapshot = WeeklyReviewSnapshot(
                    weekStart: base.weekStart,
                    referenceDate: base.referenceDate,
                    current: base.current,
                    previous: base.previous,
                    confirmedInsights: insights
                )
            }
        }
        .accessibilityIdentifier("weeklyReview.page")
    }

    // MARK: - 刊头双线（个人周刊小报）

    private func masthead(_ snapshot: WeeklyReviewSnapshot) -> some View {
        let weekOfYear = calendar.component(.weekOfYear, from: snapshot.weekStart)
        let year = calendar.component(.year, from: snapshot.weekStart)
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("HOLO WEEKLY")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .kerning(2.2)
                    .foregroundStyle(Color.holoAlmanacInk)
                Spacer()
                Text(String(format: "NO. %02d · %d", weekOfYear, year))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.bottom, 5)

            Rectangle()
                .fill(Color.holoAlmanacInk)
                .frame(height: 1.5)
            Rectangle()
                .fill(Color.holoAlmanacInk.opacity(0.65))
                .frame(height: 0.5)
        }
    }

    // MARK: - 有数据（个人周刊小报：无白卡编排 + 衬线排印 + 细线目录）

    private func reviewContent(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead(snapshot)
                .padding(.bottom, 22)

            // 日期区间 + 衬线大刊题
            Text(weekRangeText(snapshot))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(Color.holoToolTextSecondary)

            Text(editorialHeadline(snapshot))
                .font(.holoEditorialSerif(size: 27, bold: true))
                .kerning(0.6)
                .foregroundStyle(Color.holoAlmanacInk)
                .lineSpacing(6)
                .padding(.top, 6)
                .padding(.bottom, 16)

            // 朱砂竖线引言（同期比 / 首周）
            editorialLeadQuote(snapshot)
                .padding(.bottom, 26)

            // 无卡主角大数字区
            heroMetricBand(snapshot)
                .padding(.bottom, 24)

            // 纸本目录式四项足迹（零白卡、零 SF Symbol 堆砌）
            footprintsEditorialList(snapshot)

            // 确认过的理解（编者按）
            confirmedInsightsSection
                .padding(.top, 26)

            // 底部收束：朱砂圆印 + 结语
            editorialFooter(snapshot)
                .padding(.top, 32)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 8)
    }

    /// 根据本周活跃度与是否首周给出克制、无感叹号的周刊标题
    private func editorialHeadline(_ snapshot: WeeklyReviewSnapshot) -> String {
        if snapshot.previous == nil {
            return String(localized: "你的第一份个人周刊")
        }
        let total = snapshot.current.recordTotal
        if total <= 3 {
            return String(localized: "安静而克制的一周")
        }
        if let prev = snapshot.previous, total > prev.recordTotal {
            return String(localized: "比上周多留下一些痕迹")
        }
        return String(localized: "平稳推进的一周")
    }

    /// 朱砂竖线引言
    private func editorialLeadQuote(_ snapshot: WeeklyReviewSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Color.holoPrimary)
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(leadSentence(snapshot))
                    .font(.holoEditorialSerif(size: 14.5, bold: false))
                    .foregroundStyle(Color.holoAlmanacInk.opacity(0.86))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leadSentence(_ snapshot: WeeklyReviewSnapshot) -> String {
        guard let previous = snapshot.previous else {
            return String(localized: "记账、想法与任务都会汇入这里。这是你的第一份周回顾，以后每周都会留下一页。")
        }
        let current = snapshot.current.recordTotal
        let last = previous.recordTotal
        if current > last {
            return String(format: String(localized: "本周共留下 %d 条记录，比上周多 %d 条。散落在一周里的碎片，都安静归档了。"), current, current - last)
        } else if current < last {
            return String(format: String(localized: "本周共留下 %d 条记录，比上周少 %d 条。慢一点的节奏，同样值得被记住。"), current, last - current)
        } else {
            return String(format: String(localized: "本周共留下 %d 条记录，与上周恰好持平。稳定的节奏本身就是一种积累。"), current)
        }
    }

    /// 无卡主角大数字带（上下 0.5pt 细线分隔）
    private func heroMetricBand(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            hairline
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOTAL FOOTPRINTS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.8)
                        .foregroundStyle(Color.holoToolTextSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(snapshot.current.recordTotal)")
                            .font(.holoHeroNumber(size: 46))
                            .foregroundStyle(Color.holoAlmanacInk)
                            .monospacedDigit()
                        Text(String(localized: "条足迹"))
                            .font(.holoEditorialSerif(size: 14, bold: false))
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }

                Spacer()

                if let previous = snapshot.previous {
                    let current = snapshot.current.recordTotal
                    let last = previous.recordTotal
                    if current > last {
                        DeltaPill(diff: current - last, direction: .up)
                    } else if current < last {
                        DeltaPill(diff: last - current, direction: .flat)
                    } else {
                        DeltaPill(diff: 0, direction: .flat)
                    }
                } else {
                    Text(String(localized: "首期"))
                        .font(.holoEditorialSerif(size: 12, bold: false))
                        .foregroundStyle(Color.holoPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.holoPrimary.opacity(0.65), lineWidth: 0.7)
                        )
                }
            }
            .padding(.vertical, 18)
            hairline
        }
    }

    /// 纸本目录式四项足迹（零白卡、零 SF Symbol 堆砌，01-04 等宽编号 + 衬线名 + 等宽大数字）
    private func footprintsEditorialList(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EDITION INDEX")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.bottom, 10)

            footRow(
                index: "01",
                title: String(localized: "记账"),
                subtitle: String(localized: "本周新增流水 · 含识图"),
                value: snapshot.current.transactionCount,
                unit: String(localized: "笔"),
                delta: deltaPill(current: snapshot.current.transactionCount, previous: snapshot.previous?.transactionCount)
            )
            hairline
            footRow(
                index: "02",
                title: String(localized: "想法"),
                subtitle: String(localized: "本周新建"),
                value: snapshot.current.thoughtCount,
                unit: String(localized: "条"),
                delta: deltaPill(current: snapshot.current.thoughtCount, previous: snapshot.previous?.thoughtCount)
            )
            hairline
            footRow(
                index: "03",
                title: String(localized: "完成任务"),
                subtitle: String(localized: "本周完成"),
                value: snapshot.current.completedTaskCount,
                unit: String(localized: "个"),
                delta: deltaPill(current: snapshot.current.completedTaskCount, previous: snapshot.previous?.completedTaskCount)
            )
            hairline
            footRow(
                index: "04",
                title: String(localized: "习惯打卡"),
                subtitle: String(localized: "本周打卡天数"),
                value: snapshot.current.habitDays,
                unit: String(localized: "天"),
                delta: deltaPill(current: snapshot.current.habitDays, previous: snapshot.previous?.habitDays)
            )
            hairline
        }
    }

    private func footRow(
        index: String,
        title: String,
        subtitle: String,
        value: Int,
        unit: String,
        delta: DeltaPill?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(index)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.holoChartStone)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoEditorialSerif(size: 16, bold: true))
                    .foregroundStyle(Color.holoAlmanacInk)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)")
                    .font(.holoHeroNumber(size: 24))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? Color.holoChartStone : Color.holoAlmanacInk)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }

            if let delta {
                delta
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) \(unit)\(delta?.accessibilityText ?? "")")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.holoAlmanacInk.opacity(0.14))
            .frame(height: 0.5)
    }

    /// 底部朱砂小印 + 结语
    private func editorialFooter(_ snapshot: WeeklyReviewSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(Color.holoPrimary.opacity(0.82), lineWidth: 1.1)
                    .frame(width: 36, height: 36)
                Text(snapshot.previous == nil ? String(localized: "初印") : String(localized: "已阅"))
                    .font(.holoEditorialSerif(size: 10.5, bold: true))
                    .foregroundStyle(Color.holoPrimary)
                    .kerning(0.8)
            }
            .rotationEffect(.degrees(-10))
            .accessibilityHidden(true)

            Text(closingText(snapshot))
                .font(.holoEditorialSerif(size: 13, bold: false))
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    /// 首周用「下一页」期待感文案；其余周用留存向收尾
    private func closingText(_ snapshot: WeeklyReviewSnapshot) -> String {
        snapshot.previous == nil
            ? String(localized: "下一周，这里会再长出一页")
            : String(localized: "你写下的一笔一画，Holo 都替你收着")
    }

    private func deltaPill(current: Int, previous: Int?) -> DeltaPill? {
        guard let previous else { return nil }
        if current > previous { return DeltaPill(diff: current - previous, direction: .up) }
        if current < previous { return DeltaPill(diff: previous - current, direction: .flat) }
        return DeltaPill(diff: 0, direction: .flat)
    }

    // MARK: - 空态（召唤页，无行动按钮；像诗集扉页般优雅留白）

    private func emptyState(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead(snapshot)
                .padding(.bottom, 44)

            Text(weekRangeText(snapshot))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(Color.holoToolTextSecondary)

            Text(String(localized: "本周还没有足迹"))
                .font(.holoEditorialSerif(size: 28, bold: true))
                .foregroundStyle(Color.holoAlmanacInk)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.holoPrimary)
                    .frame(width: 2)
                    .padding(.vertical, 2)

                Text(String(localized: "现在开始记录，积攒属于你的人生数据库。\n本周一以来的记录，都会出现在这里。"))
                    .font(.holoEditorialSerif(size: 14.5, bold: false))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineSpacing(6)
            }
            .padding(.top, 18)

            // 极简线描留白装饰（不放行动按钮，保留召唤页产品约定）
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.holoAlmanacInk.opacity(0.16))
                    .frame(height: 0.6)
                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 5, height: 5)
                Rectangle()
                    .fill(Color.holoAlmanacInk.opacity(0.16))
                    .frame(height: 0.6)
            }
            .padding(.top, 64)
            .padding(.horizontal, 44)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    // MARK: - 格式化

    /// 标题区间文本「MM.dd – MM.dd」（周一 ~ 周日）
    private func weekRangeText(_ snapshot: WeeklyReviewSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM.dd"
        let start = formatter.string(from: snapshot.weekStart)
        let end = formatter.string(
            from: calendar.date(byAdding: .day, value: 6, to: snapshot.weekStart) ?? snapshot.weekStart
        )
        return "\(start) — \(end)"
    }

    /// 埋点参数：周一日期 yyyy-MM-dd（与后端白名单约定一致）
    @ViewBuilder
    private var confirmedInsightsSection: some View {
        // 本周你确认过的理解（东林 2026-11-08 拍板接入）：一个发现的确认结果进入周报
        if let snapshot, !snapshot.confirmedInsights.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("EDITOR'S NOTES · 确认过的理解")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.6)
                    .foregroundStyle(Color.holoToolTextSecondary)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.confirmedInsights, id: \.self) { text in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color.holoSuccess)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(text)
                                .font(.holoEditorialSerif(size: 14.5, bold: false))
                                .foregroundStyle(Color.holoAlmanacInk.opacity(0.9))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { hairline }
            .accessibilityIdentifier("weeklyReview.confirmedInsights")
        }
    }

    /// 本周（周一零点起）在「一个发现」确认的理解；空数组=本周无确认。
    private static func confirmedInsightsThisWeek(now: Date, calendar: Calendar) async -> [String] {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return [] }
        let resolved = (try? await repository.resolvedKnowledgeAll(now: now)) ?? []
        return WeeklyReviewMath.selectConfirmedInsights(from: resolved, now: now, calendar: calendar)
    }

    private static func analyticsDayKey(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - 导航容器底色（iOS 18+ 条件修饰）

/// 见 body 内注释：导航容器底色与页面底色统一为 holoPaper，杜绝转场/加载首帧双色伪影
private struct WeekReviewNavContainerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.containerBackground(Color.holoPaper, for: .navigation)
        } else {
            content
        }
    }
}

// MARK: - 涨跌胶囊

/// 涨绿（鼓励）；降与持平统一灰色（只陈述、不惩罚）
private struct DeltaPill: View {
    enum Direction {
        case up
        case flat
    }

    let diff: Int
    let direction: Direction

    var accessibilityText: String {
        switch (direction, diff) {
        case (.up, _): return "+\(diff)"
        case (.flat, 0): return String(localized: "持平")
        case (.flat, _): return "-\(diff)"
        }
    }

    var body: some View {
        Text(labelText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(direction == .up ? .holoToolSuccess : .holoTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                direction == .up
                    ? Color.holoToolSuccess.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        direction == .up ? Color.clear : Color.holoToolBorder,
                        lineWidth: 0.5
                    )
            )
    }

    private var labelText: String {
        switch (direction, diff) {
        case (.up, _): return String(localized: "+\(diff)")
        case (.flat, 0): return String(localized: "持平")
        case (.flat, _): return String(localized: "−\(diff)")
        }
    }
}
