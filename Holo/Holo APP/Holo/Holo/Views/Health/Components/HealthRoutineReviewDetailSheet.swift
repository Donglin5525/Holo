//
//  HealthRoutineReviewDetailSheet.swift
//  Holo
//
//  近期作息回顾的依据弹层（健康分析方案第三步）：两段窗口的具体日期、
//  参与晚数、各指标中位数、达到门槛的变化与对应归属日。
//  用户能按日期复算——每一条结论都写清用了哪些晚。
//

import SwiftUI

struct HealthRoutineReviewDetailSheet: View {
    let review: HealthRoutineReview?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                if let review {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        windowCard(review)
                        metricsCard(review)
                        if !review.changes.isEmpty {
                            changesCard(review)
                        }
                        footnote
                    }
                    .padding(HoloSpacing.md)
                } else {
                    Text("暂无可用记录")
                        .holoText(.supporting)
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(HoloSpacing.lg)
                }
            }
            .background(Color.holoToolBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Color.holoPrimary)
                }
            }
            .navigationTitle("作息回顾依据")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents([.medium, .large])
    }

    /// 两段窗口：最近 14 天与参考 28 天的具体日期、参与晚数
    private func windowCard(_ review: HealthRoutineReview) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("比较窗口")
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)

            windowRow(
                title: String(localized: "最近 14 天"),
                range: review.recentRange,
                nights: review.recentNightsTotal
            )
            windowRow(
                title: String(localized: "此前 28 天"),
                range: review.referenceRange,
                nights: review.referenceNightsTotal
            )
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func windowRow(title: String, range: HealthDateRange, nights: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text("\(Self.dayFormatter.string(from: range.start))–\(Self.dayFormatter.string(from: range.end))")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
            Text(String(localized: "\(nights) 晚记录"))
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    /// 各指标近期事实：时长中位数 / 典型入睡 / 典型记录结束
    private func metricsCard(_ review: HealthRoutineReview) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("近期事实")
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)

            if let duration = review.durationMedianHours {
                metricRow(String(localized: "主睡眠时长中位数"), SleepStagesCard.formatHours(duration))
            } else {
                metricRow(String(localized: "主睡眠时长中位数"), String(localized: "样本不足"))
            }
            metricRow(
                String(localized: "典型入睡"),
                review.onsetSummary.typical.map { HealthView.clockText($0) } ?? unavailableClock(review.onsetSummary.nights)
            )
            metricRow(
                String(localized: "典型记录结束"),
                review.recordEndSummary.typical.map { HealthView.clockText($0) } ?? unavailableClock(review.recordEndSummary.nights)
            )
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func unavailableClock(_ nights: Int) -> String {
        nights > 0 ? String(localized: "时间点分散") : String(localized: "样本不足")
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.subheadline))
                .foregroundColor(.holoToolText)
            Spacer()
            Text(value)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(.holoToolText)
                .monospacedDigit()
        }
    }

    /// 达到门槛的变化：每条写清参与晚数、中位数与对应日期
    private func changesCard(_ review: HealthRoutineReview) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("达到门槛的变化")
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)

            ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(changeTitle(change))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(.holoToolText)
                        Spacer()
                        if change.sustained {
                            Text("近两周持续")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoToolSuccess)
                        }
                    }
                    Text(changeDetail(change))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func changeTitle(_ change: HealthRoutineReview.MetricChange) -> String {
        switch change.metric {
        case .duration: return String(localized: "主睡眠时长")
        case .onset: return String(localized: "入睡时间")
        case .recordEnd: return String(localized: "记录结束时间")
        }
    }

    /// 变化依据行：两段中位数（时长按小时、钟点按时刻）+ 参与晚数 + 首末参与日
    private func changeDetail(_ change: HealthRoutineReview.MetricChange) -> String {
        func medianText(_ value: Double) -> String {
            if change.metric == .duration {
                return SleepStagesCard.formatHours(value)
            }
            return HealthView.clockText(HealthClockMinute(minutes: Int(value.rounded())))
        }
        let nights = change.validNights
        let first = nights.first.map { Self.dayFormatter.string(from: $0) } ?? ""
        let last = nights.last.map { Self.dayFormatter.string(from: $0) } ?? ""
        return String(localized: "此前中位数 \(medianText(change.referenceMedian)) → 近期 \(medianText(change.recentMedian))（\(change.referenceNights) 晚 → \(change.recentNights) 晚）· 参与日 \(first)–\(last)")
    }

    private var footnote: some View {
        Text("比较用两段窗口的中位数；入睡/结束时刻沿跨午夜连续换算。缺记录的晚上不进入统计。达到门槛且方向持续的变化才标注「持续」。")
            .holoText(.metadata)
            .foregroundColor(.holoToolTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
