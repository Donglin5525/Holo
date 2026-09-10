//
//  DailyActivityPatternCard.swift
//  Holo
//
//  「一天怎么动的」24 小时步数分布（二期步数详情页）：
//  自绘 24 柱 + 白天窗静坐区间高亮 + 活动时间窗/最活跃小时标注。
//  口径与 AI 数据字典一致：小时粒度，静坐=白天 8-21 时整小时步数低于 100。
//

import SwiftUI

// MARK: - DailyActivityPatternCard

struct DailyActivityPatternCard: View {
    let hourly: HourlyStepsData
    private var features: ActivityDistributionAnalyzer.Features

    init(hourly: HourlyStepsData) {
        self.hourly = hourly
        self.features = ActivityDistributionAnalyzer.features(hourlySteps: hourly.hourly)
    }

    private var bars: [Double] { Array(hourly.hourly.prefix(24)) }
    private var maxSteps: Double { bars.max() ?? 0 }
    private var totalSteps: Double { bars.reduce(0, +) }

    /// 白天窗内最长连续安静小时区间；≥2 小时才值得标注
    private var longestSedentaryRange: Range<Int>? {
        let range = ActivityDistributionAnalyzer.longestQuietRange(hourlySteps: bars)
        return (range?.count ?? 0) >= 2 ? range : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack {
                Text("一天怎么动的")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if let sedentary = longestSedentaryRange {
                    Text("最长静坐 \(sedentary.count) 小时")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoChart4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoChart4.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            chart

            summaryRow

            if let sedentary = longestSedentaryRange {
                Text("\(hourLabel(sedentary.lowerBound))–\(hourLabel(sedentary.upperBound - 1)) 连续静坐 \(sedentary.count) 小时，是今天最长的静坐段。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoNestedCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: - 24 柱图（自绘，静坐区间高亮）

    private var chart: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let barWidth = (proxy.size.width - 23 * 2) / 24
                ZStack(alignment: .bottomLeading) {
                    if let sedentary = longestSedentaryRange {
                        // 高亮带覆盖 [lowerBound 柱左缘, 末柱右缘]，左右各留 1pt 呼吸；
                        // HStack 柱间距为 2，中心 x = 首柱左缘 + 带宽/2
                        let bandWidth = CGFloat(sedentary.count) * barWidth + CGFloat(sedentary.count - 1) * 2 + 2
                        let bandCenter = CGFloat(sedentary.lowerBound) * (barWidth + 2) + bandWidth / 2
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.holoChart4.opacity(0.5), lineWidth: 1)
                            .background(Color.holoChart4.opacity(0.06).cornerRadius(6))
                            .frame(width: bandWidth, height: proxy.size.height)
                            .position(x: bandCenter, y: proxy.size.height / 2)
                    }

                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<bars.count, id: \.self) { hour in
                            let isQuiet = hour >= 8 && hour < 22 && bars[hour] < 100 && totalSteps > 0
                            Capsule()
                                .fill(isQuiet ? Color.holoTextSecondary.opacity(0.3) : Color.holoChart6)
                                .frame(width: barWidth,
                                       height: maxSteps > 0 ? max(3, bars[hour] / maxSteps * proxy.size.height) : 3)
                        }
                    }
                }
            }
            .frame(height: 96)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18, 23], id: \.self) { hour in
                    Text("\(hour)")
                        .font(.system(size: 9))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: hour == 0 || hour == 23 ? .infinity : .infinity, alignment: hour == 0 ? .leading : (hour == 23 ? .trailing : .center))
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(windowText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text("活动时间窗")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(features.peakHour.map { "\(hourLabel($0))" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text("最活跃时段")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(eveningText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text("晚间步数占比")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.holoBorder).frame(height: 1)
        }
    }

    private var windowText: String {
        guard let start = features.activeWindowStartHour, let end = features.activeWindowEndHour else {
            return "—"
        }
        return "\(hourLabel(start))–\(hourLabel(end))"
    }

    private var eveningText: String {
        guard let share = features.eveningStepShare else { return "—" }
        return "\(Int((share * 100).rounded()))%"
    }

    private func hourLabel(_ hour: Int) -> String {
        hour < 10 ? " \(hour) 时" : "\(hour) 时"
    }
}

#Preview {
    let hourly = HourlyStepsData(date: Calendar.current.startOfDay(for: Date()), hourly: [
        0, 0, 0, 0, 0, 0, 50, 850, 1450, 600, 1100, 900,
        400, 80, 0, 0, 80, 200, 1600, 1900, 1200, 500, 100, 0
    ])
    return DailyActivityPatternCard(hourly: hourly)
        .padding()
        .background(Color.holoBackground)
}
