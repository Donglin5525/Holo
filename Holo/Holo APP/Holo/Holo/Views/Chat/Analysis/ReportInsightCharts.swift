//
//  ReportInsightCharts.swift
//  Holo
//
//  深度分析报告图表组件（2026-09-24 按 iOS 设计规范重写，原型 v1 定稿）：
//  - ReportMetricHighlight：观察卡内数据强调（成对断言=水平对比条；单值=大字数字行）
//  - ReportDeltaBadge：变化幅度徽章（方向+幅度，胶囊形态，观察卡/依据卡共用）
//  - ReportEvidenceMetricRow：依据卡头部指标行
//  - ReportTrendChart：趋势速览折线卡（对齐财务折线规格）
//  设计纪律：图必须提供文字给不了的形状直觉（趋势/比例/对比），否则不画——
//  单值永不画柱；无嵌套面板；语义文本样式（动态字体）；语义色（自动深色）；
//  数据线用 holoChart1 蓝，holoPrimary 橙只用于本期条与徽章。
//

import SwiftUI
import Charts

// MARK: - 数值格式化

enum ReportMetricNumberFormatting {
    /// 报告图表数值：整数直出（千分位），万级缩写（12,400 → 1.24万），小数保留 1 位。
    static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 10_000 {
            return String(format: "%.2f万", value / 10_000)
        }
        if magnitude >= 100 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
        }
        if magnitude == magnitude.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// 变化幅度：有基线且基线>0 时给（方向箭头+幅度, 是否下降）；
    /// 基线为 0→有值视为新增；变动 <0.5% 视为持平；无基线返回 nil。
    /// 只描述方向与幅度，不预设好坏（支出升≠坏、睡眠升≠好，方向性由断言语义承载）。
    static func changeBadge(value: Double?, baseline: Double?) -> (text: String, isDown: Bool)? {
        guard let value, let baseline else { return nil }
        if baseline <= 0 {
            return value > 0 ? ("新增", false) : nil
        }
        let ratio = (value - baseline) / baseline
        if abs(ratio) < 0.005 { return ("基本持平", false) }
        let percent = abs(ratio) * 100
        let magnitude = percent >= 10
            ? String(format: "%.0f%%", percent)
            : String(format: "%.1f%%", percent)
        return (ratio > 0 ? "↑ \(magnitude)" : "↓ \(magnitude)", ratio < 0)
    }
}

// MARK: - 变化徽章

/// 胶囊徽章：橙底 9% + holoPrimary 字，观察卡对比条与依据卡指标行共用同一形态。
struct ReportDeltaBadge: View {
    let text: String
    let isDown: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.holoPrimary.opacity(0.09))
            .clipShape(Capsule())
    }
}

// MARK: - 观察·数据强调

/// 观察卡内数据强调区：断言有基线 → 每条一组水平对比条（标签/条/右对齐数值）；
/// 只有单值 → 大字数字行（不画柱，数字本身就是视觉锚点）。最多两组。
struct ReportMetricHighlight: View {
    let assertions: [HoloRenderedMetricAssertion]

    private struct PairGroup {
        let value: Double
        let baseline: Double
        let unit: String?
        let note: String?
    }

    private var pairGroups: [PairGroup] {
        assertions
            .filter { $0.value != nil && $0.baselineValue != nil }
            .prefix(2)
            .map { PairGroup(value: $0.value ?? 0, baseline: $0.baselineValue ?? 0, unit: $0.unit, note: comparisonNote($0)) }
    }

    private var singleAssertion: HoloRenderedMetricAssertion? {
        guard pairGroups.isEmpty else { return nil }
        return assertions.first { $0.value != nil }
    }

    /// 口径小字：comparison 字段是云端对这条数字的语义描述（如「2026-09 支出合计」）；
    /// 但部分报告里它是 up/down 这类方向枚举（无信息量）——过滤掉，只保留有意义的描述。
    private func comparisonNote(_ assertion: HoloRenderedMetricAssertion) -> String? {
        guard let note = assertion.comparison?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else { return nil }
        let directionWords: Set<String> = ["up", "down", "higher", "lower", "increase", "decrease", "same", "flat"]
        if directionWords.contains(note.lowercased()) { return nil }
        return note
    }

    var body: some View {
        if !pairGroups.isEmpty {
            VStack(spacing: 14) {
                ForEach(Array(pairGroups.enumerated()), id: \.offset) { _, group in
                    comparisonBars(group)
                }
            }
        } else if let single = singleAssertion {
            inlineMetric(single)
        }
    }

    /// 水平对比条：标签在左、条在中（按值比例）、数值右对齐。
    /// 两条数据用纯 SwiftUI 自绘——不必为此动用图表框架，比例即信息。
    private func comparisonBars(_ group: PairGroup) -> some View {
        let scale = max(group.value, group.baseline, 1)
        let badge = ReportMetricNumberFormatting.changeBadge(value: group.value, baseline: group.baseline)
        return VStack(alignment: .leading, spacing: 8) {
            barRow(label: "本期", value: group.value, unit: group.unit,
                   fraction: group.value / scale, isCurrent: true)
            barRow(label: "上期", value: group.baseline, unit: nil,
                   fraction: group.baseline / scale, isCurrent: false)
            if let badge {
                ReportDeltaBadge(text: badge.text, isDown: badge.isDown)
            }
            if let note = group.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(group: group, badge: badge))
    }

    private func barRow(label: String, value: Double, unit: String?, fraction: Double, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 32, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoTextSecondary.opacity(0.10))
                    Capsule()
                        .fill(isCurrent ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.30))
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            Text(valueText(value, unit: unit, isCurrent: isCurrent))
                .font(isCurrent ? .footnote.weight(.bold) : .footnote.weight(.medium))
                .foregroundColor(isCurrent ? .holoTextPrimary : .holoTextSecondary)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(_ value: Double, unit: String?, isCurrent: Bool) -> String {
        var text = ReportMetricNumberFormatting.compact(value)
        if isCurrent, let unit, !unit.isEmpty {
            text += " \(unit)"
        }
        return text
    }

    private func accessibilitySummary(group: PairGroup, badge: (text: String, isDown: Bool)?) -> Text {
        var parts: [String] = []
        parts.append("本期 \(valueText(group.value, unit: group.unit, isCurrent: true))")
        parts.append("上期 \(valueText(group.baseline, unit: nil, isCurrent: false))")
        if let badge { parts.append(badge.text) }
        return Text(parts.joined(separator: "，"))
    }

    /// 单值大字数字行：无面板底色、贴正文左缘（消灭盒中盒与装饰色块）。
    private func inlineMetric(_ assertion: HoloRenderedMetricAssertion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ReportMetricNumberFormatting.compact(assertion.value ?? 0))
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundColor(.holoTextPrimary)
                if let unit = assertion.unit, !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            if let note = comparisonNote(assertion) {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 依据·指标行

/// 依据卡头部指标行：把口径句里的核心数字提为大字（title2 rounded），徽章与观察卡同款。
struct ReportEvidenceMetricRow: View {
    let value: Double
    let unit: String?
    let baseline: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(ReportMetricNumberFormatting.compact(value))
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .foregroundColor(.holoTextPrimary)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.footnote.weight(.bold))
                    .foregroundColor(.holoTextSecondary)
            }
            if let badge = ReportMetricNumberFormatting.changeBadge(value: value, baseline: baseline) {
                ReportDeltaBadge(text: badge.text, isDown: badge.isDown)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 趋势速览

/// 趋势折线卡（对齐财务页 LineChartView 视格）：标准 holoCard；线 2.25pt round +
/// catmullRom；面积渐变 0.14→0.005；Y 轴 4 刻度+浅网格（不隐藏，防失真）；
/// X 轴日期标签 caption2；末端圆点标记当前值。标注「本机数据」：序列来自设备
/// 本地回查，与云端核验指标同源但未逐位对账。
struct ReportTrendChart: View {
    let series: HoloReportTrendSeries
    let weeklyAggregated: Bool

    private var points: [HoloReportTrendSeries.Point] { series.points }
    private var values: [Double] { points.map(\.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            noteCapsule
            chart
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.holoChart1)
                    .frame(width: 7, height: 7)
                Text(series.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.holoTextPrimary)
            }
            Spacer(minLength: 12)
            Text(rangeText)
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
                .monospacedDigit()
        }
    }

    private var noteCapsule: some View {
        Text(weeklyAggregated ? "本机数据 · 按周" : "本机数据 · 逐日")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.holoTextSecondary.opacity(0.10))
            .clipShape(Capsule())
    }

    private var rangeText: String {
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return "\(ReportMetricNumberFormatting.compact(low))–\(ReportMetricNumberFormatting.compact(high)) \(series.unitLabel)"
    }

    private var chart: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("数值", point.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.holoChart1.opacity(0.14), Color.holoChart1.opacity(0.005)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("数值", point.value)
                )
                .foregroundStyle(Color.holoChart1)
                .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                // 末端点：当前值的位置锚（只标最后一个点，避免与大字体轴标签争位）
                if index == points.count - 1 {
                    PointMark(
                        x: .value("日期", point.date),
                        y: .value("数值", point.value)
                    )
                    .symbolSize(30)
                    .foregroundStyle(Color.holoChart1)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(centered: false)
                    .foregroundStyle(Color.holoDivider.opacity(0.9))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.caption2)
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.9))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .frame(height: 128)
    }

    private var accessibilitySummary: Text {
        let first = points.first
        let last = points.last
        let high = values.max() ?? 0
        var parts: [String] = [series.title]
        if let first, let last {
            parts.append("从 \(ReportMetricNumberFormatting.compact(first.value)) 到 \(ReportMetricNumberFormatting.compact(last.value)) \(series.unitLabel)")
        }
        parts.append("最高 \(ReportMetricNumberFormatting.compact(high)) \(series.unitLabel)")
        parts.append("数据来自本机")
        return Text(parts.joined(separator: "，"))
    }
}
