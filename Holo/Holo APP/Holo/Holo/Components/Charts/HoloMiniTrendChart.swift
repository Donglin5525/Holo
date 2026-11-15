import SwiftUI
import Charts
import UIKit

/// 迷你趋势档（弹层等小空间）：一行读数（最新值 + 较上次涨跌）+ 真实时间短线 + 首尾日期。
/// 断档按真实日期拉开（沿用 2026-10-27 拍板语义）；末点用公共件「选中点」样式（白描边实心）。
/// 画法归公共组件——打卡弹层旧手绘 HabitMiniTrendLine 退役（图表规范「唯一实现」）。
struct HoloMiniTrendChart: View {
    struct Point: Equatable {
        let date: Date
        let value: Double
    }

    let points: [Point]
    let color: Color
    let title: String
    var valueText: (Double) -> String = HoloChartFormat.number
    /// 涨跌好坏语义：true = 涨红跌绿（支出类）；false = 涨绿跌红（完成量类）；
    /// nil = 中性色（测量类——「跌=好」取决于目标方向，不预设立场）
    var deltaRisingIsBad: Bool? = nil
    var height: CGFloat = 46

    private var calendar: Calendar { .current }

    /// 首点起的天偏移：断档期如实拉开
    private var offsets: [Double] {
        guard let first = points.first else { return [] }
        return points.map { Double(max(calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date),
                                                              to: calendar.startOfDay(for: $0.date)).day ?? 0, 0)) }
    }
    private var span: Double { max(offsets.last ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if points.count >= 2 {
                readoutRow
                miniChart
                dateRow
            } else if let only = points.first {
                // 单点：读数照常，线退化为居中一个点
                HStack(spacing: 8) {
                    Text("唯一记录 \(HoloChartFormat.date(only.date))")
                        .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    Text(valueText(only.value)).font(.headline.weight(.semibold))
                        .monospacedDigit().foregroundStyle(Color.holoToolText)
                }
                Chart {
                    PointMark(x: .value("时间", 0), y: .value("数值", only.value))
                        .foregroundStyle(color)
                        .symbol { Circle().fill(color).stroke(Color.holoToolSurface, lineWidth: 1.5) }
                }
                .chartXScale(domain: -1...1)
                .chartYScale(domain: (only.value - 1)...(only.value + 1))
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，最新 \(points.last.map { valueText($0.value) } ?? "无记录")")
    }

    private var readoutRow: some View {
        HStack(spacing: 8) {
            Text("最新 \(HoloChartFormat.date(points[points.count - 1].date))")
                .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
            Text(valueText(points[points.count - 1].value))
                .font(.headline.weight(.semibold)).monospacedDigit().foregroundStyle(Color.holoToolText)
            let delta = points[points.count - 1].value - points[points.count - 2].value
            if abs(delta) > 0.0001 {
                let rising = delta >= 0
                let tone: Color = deltaRisingIsBad
                    .map { rising == $0 ? Color.holoChartOutflow : Color.holoChartInflow }
                    ?? Color.holoToolTextSecondary
                Text("\(rising ? "▲" : "▼") \(String(format: "%.1f", abs(delta))) 较上次")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tone.opacity(0.12)))
            }
        }
    }

    private var miniChart: some View {
        Chart {
            ForEach(points.indices, id: \.self) { index in
                LineMark(x: .value("时间", offsets[index]), y: .value("数值", points[index].value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                PointMark(x: .value("时间", offsets[index]), y: .value("数值", points[index].value))
                    .foregroundStyle(color.opacity(index == points.count - 1 ? 1 : 0.85))
                    // 自定义 symbol 不吃 symbolSize，必须 frame 定径：末点 10pt 白圈（选中点语言），常点 5pt
                    .symbol {
                        if index == points.count - 1 {
                            Circle().fill(color).stroke(Color.holoToolSurface, lineWidth: 1.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Circle().fill(color.opacity(0.85))
                                .frame(width: 5, height: 5)
                        }
                    }
            }
        }
        // 两端各留 3% 余量：末点白圈不被图缘裁切
        .chartXScale(domain: (0 - span * 0.03)...(span * 1.03))
        .chartYScale(domain: yDomain, range: .plotDimension(startPadding: 4, endPadding: 4))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: height)
    }

    private var yDomain: ClosedRange<Double> {
        HoloChartGeometry.niceDomain(values: points.map(\.value), includesZero: false)
    }

    private var dateRow: some View {
        HStack {
            Text(HoloChartFormat.date(points[0].date))
            Spacer(minLength: 8)
            Text(HoloChartFormat.date(points[points.count - 1].date))
        }
        .font(.system(size: 10.5)).foregroundStyle(Color.holoToolTextSecondary)
    }
}
