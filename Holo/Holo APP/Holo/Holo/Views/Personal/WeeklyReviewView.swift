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
                    emptyState
                }
            } else {
                ProgressView()
                    .padding(.top, 120)
            }
        }
        .background(Color.holoBackground)
        .navigationTitle(String(localized: "每周回顾"))
        .navigationBarTitleDisplayMode(.inline)
        confirmedInsightsSection
        .task {
            guard snapshot == nil else { return }
            let insights = await Self.confirmedInsightsThisWeek(calendar: calendar)
            let made = aggregator.makeSnapshot(calendar: calendar, confirmedInsights: insights)
            snapshot = made
            HoloProductAnalytics.shared.track(
                .weeklyReviewViewed,
                ["weekStart": Self.analyticsDayKey(made.weekStart, calendar: calendar)]
            )
        }
        .accessibilityIdentifier("weeklyReview.page")
    }

    // MARK: - 有数据

    private func reviewContent(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(spacing: 14) {
            heroCard(snapshot)
            footprintsCard(snapshot)
            Text(closingText(snapshot))
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .padding(.horizontal, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// 主角卡：总量数字 + 同期比副句（或首周条幅）
    private func heroCard(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: String(localized: "本周足迹 · %@"), weekRangeText(snapshot)))
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(snapshot.current.recordTotal)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text(String(localized: "条"))
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextSecondary)
            }
            heroDeltaLine(snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .holoSurface()
    }

    @ViewBuilder
    private func heroDeltaLine(_ snapshot: WeeklyReviewSnapshot) -> some View {
        if let previous = snapshot.previous {
            let current = snapshot.current.recordTotal
            let last = previous.recordTotal
            if current > last {
                HStack(spacing: 6) {
                    Text(String(localized: "记账·想法·任务合计，比上周多"))
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                    DeltaPill(diff: current - last, direction: .up)
                }
            } else if current < last {
                Text(String(localized: "记账·想法·任务合计，比上周少 \(last - current) 条"))
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text(String(localized: "记账·想法·任务合计，与上周持平"))
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
            }
        } else {
            // 首周：没有上周同期数据，不显示对比，换首周条幅
            // 图标用 SF Symbol "leaf"（原型 🌱 的落地映射，与个人页「我的积累」同符号、
            // 存在性有生产实证）——Text(verbatim:) emoji 在染色上下文会退化为单色替代字形
            HStack(spacing: 8) {
                Image(systemName: "leaf")
                    .font(.system(size: 12, weight: .medium))
                Text(String(localized: "这是你的第一份周回顾"))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.holoPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 4)
        }
    }

    /// 四项足迹列表卡：涨跌胶囊直接跟在数字后（融合版）
    private func footprintsCard(_ snapshot: WeeklyReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            footRow(
                icon: "banknote",
                title: String(localized: "记账"),
                subtitle: String(localized: "本周新增流水 · 含识图"),
                value: snapshot.current.transactionCount,
                unit: String(localized: "笔"),
                delta: deltaPill(current: snapshot.current.transactionCount, previous: snapshot.previous?.transactionCount)
            )
            SettingsRowDivider()
            footRow(
                icon: "lightbulb",
                title: String(localized: "想法"),
                subtitle: String(localized: "本周新建"),
                value: snapshot.current.thoughtCount,
                unit: String(localized: "条"),
                delta: deltaPill(current: snapshot.current.thoughtCount, previous: snapshot.previous?.thoughtCount)
            )
            SettingsRowDivider()
            footRow(
                icon: "checkmark.circle",
                title: String(localized: "完成任务"),
                subtitle: String(localized: "本周完成"),
                value: snapshot.current.completedTaskCount,
                unit: String(localized: "个"),
                delta: deltaPill(current: snapshot.current.completedTaskCount, previous: snapshot.previous?.completedTaskCount)
            )
            SettingsRowDivider()
            footRow(
                icon: "flame",
                title: String(localized: "习惯打卡"),
                subtitle: String(localized: "本周打卡天数"),
                value: snapshot.current.habitDays,
                unit: String(localized: "天"),
                delta: deltaPill(current: snapshot.current.habitDays, previous: snapshot.previous?.habitDays)
            )
        }
        .holoSurface()
    }

    private func footRow(
        icon: String,
        title: String,
        subtitle: String,
        value: Int,
        unit: String,
        delta: DeltaPill?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 38, height: 38)
                .background(Color.holoPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            if let delta {
                delta
                    .frame(minWidth: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) \(unit)\(delta?.accessibilityText ?? "")")
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

    // MARK: - 空态（召唤页，无行动按钮）

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .strokeBorder(Color.holoToolBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 110, height: 110)
                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 10, height: 10)
                    .shadow(color: Color.holoPrimary.opacity(0.45), radius: 9)
            }
            .padding(.top, 52)
            .padding(.bottom, 22)
            Text(String(localized: "本周还没有足迹"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Text(String(localized: "现在开始记录，积攒属于你的人生数据库。\n本周一以来的记录，都会出现在这里。"))
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 8)
                .padding(.horizontal, 30)
        }
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
        return "\(start) – \(end)"
    }

    /// 埋点参数：周一日期 yyyy-MM-dd（与后端白名单约定一致）
    @ViewBuilder
    private var confirmedInsightsSection: some View {
        // 本周你确认过的理解（东林 2026-11-08 拍板接入）：一个发现的确认结果进入周报
        if let snapshot, !snapshot.confirmedInsights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("这段时间你确认过的理解")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(snapshot.confirmedInsights, id: \.self) { text in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.holoSuccess)
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("weeklyReview.confirmedInsights")
        }
    }

    /// 本周（周一零点起）在「一个发现」确认的理解；空数组=本周无确认。
    private static func confirmedInsightsThisWeek(calendar: Calendar) async -> [String] {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return [] }
        let resolved = (try? await repository.resolvedKnowledgeAll(now: Date())) ?? []
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        var texts: [String] = []
        for knowledge in resolved where knowledge.decision == .confirmedValid {
            if knowledge.lastUpdatedAt >= weekStart {
                texts.append(knowledge.displayText)
                if texts.count >= 5 { break }
            }
        }
        return texts
    }

    private static func analyticsDayKey(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
