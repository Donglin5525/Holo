//
//  ReportComponentViews.swift
//  Holo
//
//  深度报告数据组件视图（2026-11-20 报告改版 B 期，视觉稿 docs/design-mockups/2026-11-20-deep-report-redesign.html）。
//  组件只负责「把程序算好的数字画出来」，不做任何口径计算；数字全部来自 HoloReportComponent payload。
//

import SwiftUI
import Charts

// MARK: - 色调

extension HoloReportTone {
    var color: Color {
        switch self {
        case .good: return .holoSuccess
        case .warn: return ReportComponentStyle.amber
        case .bad: return .holoError
        case .neutral: return .holoTextSecondary
        }
    }
}

enum ReportComponentStyle {
    static let amber = Color(red: 0.851, green: 0.573, blue: 0.180)
    static let cornerRadius: CGFloat = 18

    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
            )
    }
}

struct ReportStatusChip: View {
    let text: String
    let tone: HoloReportTone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.color.opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - 分发

struct ReportComponentView: View {
    let component: HoloReportComponent

    var body: some View {
        switch component.payload {
        case .progress(let p): ReportProgressView(progress: p)
        case .kpiTiles(let p): ReportKPITilesView(tiles: p.tiles)
        case .trendLine(let p): ReportTrendLineView(trend: p)
        case .barSeries(let p): ReportBarSeriesView(series: p)
        case .habitStrip(let p): ReportHabitStripView(strip: p)
        case .periodCompare(let p): ReportPeriodCompareView(compare: p)
        case .gapCards(let p): ReportGapCardsView(cards: p.cards)
        case .milestones(let p): ReportMilestonesView(milestones: p)
        }
    }
}

// MARK: - 进度条（带时间刻度）

struct ReportProgressBar: View {
    let fraction: Double?
    let timeFraction: Double?
    var isStale: Bool = false
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.holoTextSecondary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(isStale ? Color.holoTextSecondary.opacity(0.35) : Color.holoPrimary)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
                if let timeFraction {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.holoTextPrimary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: geo.size.width * min(max(timeFraction, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct ReportProgressView: View {
    let progress: HoloReportComponent.Progress

    var body: some View {
        ReportComponentStyle.card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(progress.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    ReportStatusChip(text: progress.statusLabel, tone: progress.tone ?? .neutral)
                }
                if let current = progress.current {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Self.format(current))
                            .font(.system(size: 32, weight: .heavy))
                            .foregroundColor(progress.isStale == true ? .holoTextSecondary : .holoTextPrimary)
                            .monospacedDigit()
                        if let unit = progress.unit {
                            Text(unit)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                        }
                        if let delta = deltaText {
                            Text(delta)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.holoSuccess)
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, 10)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                if let caption = progress.caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if progress.fraction != nil || progress.timeFraction != nil {
                    ReportProgressBar(fraction: progress.fraction, timeFraction: progress.timeFraction,
                                      isStale: progress.isStale == true)
                        .padding(.top, 14)
                    HStack {
                        if let fraction = progress.fraction {
                            Text("已完成 \(Self.percent(fraction))")
                        }
                        Spacer()
                        if let time = progress.timeFraction {
                            Text("▍时间已过 \(Self.percent(time))")
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.top, 6)
                }
                if let projections = progress.projections, !projections.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(projections.prefix(2).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.holoTextSecondary)
                                Text(item.value)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill((item.tone ?? .neutral).color.opacity(0.12)))
                        }
                    }
                    .padding(.top, 14)
                }
            }
        }
    }

    private var deltaText: String? {
        guard let current = progress.current, let start = progress.start else { return nil }
        let delta = current - start
        guard abs(delta) >= 0.05 else { return nil }
        return "\(delta < 0 ? "↓" : "↑") \(Self.format(abs(delta)))\(progress.unit.map { " \($0)" } ?? "")"
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - 数字卡

struct ReportKPITilesView: View {
    let tiles: [HoloReportComponent.KPITiles.Tile]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(tiles.prefix(3).enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(tile.value)
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(.holoTextPrimary)
                            .monospacedDigit()
                        if let unit = tile.unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    if let delta = tile.delta {
                        Text(delta)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor((tile.tone ?? .neutral).color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1))
            }
        }
    }
}

// MARK: - 趋势线 / 柱状

struct ReportTrendLineView: View {
    let trend: HoloReportComponent.TrendLine

    var body: some View {
        ReportComponentStyle.card {
            VStack(alignment: .leading, spacing: 8) {
                ReportFigureHeader(title: trend.title, unit: trend.unit, showsPlanLegend: trend.planStart != nil)
                Chart {
                    if let from = trend.highlightFrom, from < trend.points.count {
                        RectangleMark(xStart: .value("起", Double(from) - 0.5),
                                      xEnd: .value("止", Double(trend.points.count) - 0.5))
                            .foregroundStyle(ReportComponentStyle.amber.opacity(0.10))
                    }
                    if let planStart = trend.planStart, let planEnd = trend.planEnd, trend.points.count > 1 {
                        LineMark(x: .value("序", 0.0), y: .value("计划", planStart), series: .value("线", "plan"))
                            .foregroundStyle(Color.holoTextSecondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                        LineMark(x: .value("序", Double(trend.points.count - 1)), y: .value("计划", planEnd), series: .value("线", "plan"))
                            .foregroundStyle(Color.holoTextSecondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                    }
                    ForEach(Array(trend.points.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("序", Double(index)), y: .value("值", point.value), series: .value("线", "actual"))
                            .foregroundStyle(Color.holoPrimary)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("序", Double(index)), y: .value("值", point.value))
                            .foregroundStyle(Color.holoPrimary)
                            .symbolSize(index == trend.points.count - 1 ? 46 : 22)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXScale(domain: -0.5...(Double(max(trend.points.count, 1)) - 0.5))
                .chartXAxis {
                    AxisMarks(values: axisIndices.map(Double.init)) { value in
                        AxisValueLabel {
                            if let raw = value.as(Double.self), let index = Int(exactly: raw), trend.points.indices.contains(index) {
                                Text(trend.points[index].label)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.holoTextSecondary.opacity(0.12))
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
                ReportFigureCaption(text: trend.caption)
            }
        }
    }

    private var axisIndices: [Int] {
        let count = trend.points.count
        guard count > 4 else { return Array(0..<count) }
        let step = max(1, (count - 1) / 3)
        var indices = Array(stride(from: 0, to: count - 1, by: step))
        indices.append(count - 1)
        return indices
    }

    private var yDomain: ClosedRange<Double> {
        let values = trend.points.map(\.value) + [trend.planStart, trend.planEnd].compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.15, 0.5)
        return (low - pad)...(high + pad)
    }
}

struct ReportBarSeriesView: View {
    let series: HoloReportComponent.BarSeries

    var body: some View {
        ReportComponentStyle.card {
            VStack(alignment: .leading, spacing: 8) {
                ReportFigureHeader(title: series.title, unit: series.unit, showsPlanLegend: false)
                Chart {
                    ForEach(Array(series.bars.enumerated()), id: \.offset) { index, bar in
                        BarMark(x: .value("期", bar.label), y: .value("值", bar.value), width: .ratio(0.55))
                            .foregroundStyle(isHighlighted(index) ? ReportComponentStyle.amber : Color.holoPrimary.opacity(0.85))
                            .cornerRadius(4)
                            .annotation(position: .top, spacing: 3) {
                                Text(ReportProgressView.format(bar.value))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.holoTextSecondary)
                            }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 140)
                ReportFigureCaption(text: series.caption)
            }
        }
    }

    private func isHighlighted(_ index: Int) -> Bool {
        guard let from = series.highlightFrom else { return false }
        return index >= from
    }
}

private struct ReportFigureHeader: View {
    let title: String
    let unit: String?
    let showsPlanLegend: Bool

    var body: some View {
        HStack {
            Text(unit.map { "\(title)（\($0)）" } ?? title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.holoTextSecondary)
            Spacer()
            if showsPlanLegend {
                HStack(spacing: 8) {
                    legend(color: .holoPrimary, text: "实际")
                    legend(color: .holoTextSecondary.opacity(0.6), text: "计划线")
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.holoTextSecondary)
        }
    }
}

private struct ReportFigureCaption: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}
