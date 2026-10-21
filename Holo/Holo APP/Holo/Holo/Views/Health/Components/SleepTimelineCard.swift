// 主睡眠时间轴：按真实时间展示，阶段、结构指标与说明分组排版。
import SwiftUI

struct SleepTimelineCard: View {
    let timeline: HealthSleepTimeline
    let detail: HealthSleepDetail
    @ScaledMetric(relativeTo: .caption2) private var tickLabelWidth: CGFloat = 48
    @ScaledMetric(relativeTo: .caption2) private var tickRowHeight: CGFloat = 20

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let napDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("整晚睡眠时间轴")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolText)
                Text("主睡眠 · 按真实时间排列")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }

            if let start = timeline.nightStart, let end = timeline.nightEnd, end > start {
                HStack(alignment: .top) {
                    anchor(value: detail.bedtime, label: "入睡", alignment: .leading)
                    Spacer(minLength: HoloSpacing.md)
                    anchor(value: detail.wakeTime, label: "记录结束", alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HoloRangeTimeline(start: start, end: end, segments: Self.displaySegments(from: timeline.segments).enumerated().map { index, segment in
                        HoloTimelineSegment(id: String(index), start: segment.start, end: segment.end,
                                            label: Self.stageLabel(segment.stage), color: Self.color(for: segment.stage))
                    })
                    tickRow(start: start, end: end)
                }
                legendRow
                Divider().overlay(Color.holoToolBorder)
                statsRow
                napRow
                readout
            } else {
                Text("暂无时间轴数据")
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func anchor(value: Date?, label: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: HoloSpacing.xs) {
            Text(value.map { Self.clockFormatter.string(from: $0) } ?? "—")
                .holoText(.sectionTitle)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
            Text(LocalizedStringKey(label))
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
    }

    private static func stageLabel(_ stage: HealthSleepSegment.Stage) -> String {
        switch stage {
        case .asleepDeep: return String(localized: "深睡")
        case .asleepCore: return String(localized: "核心睡眠")
        case .asleepREM: return "快速眼动"
        case .awake: return String(localized: "清醒")
        case .inBedAwake: return String(localized: "在床")
        case .asleepUnspecified: return String(localized: "未分期")
        }
    }

    private func tickRow(start: Date, end: Date) -> some View {
        let ticks = Self.tickTimes(windowStart: start, windowEnd: end)
        return GeometryReader { proxy in
            let capacity = max(Int(proxy.size.width / tickLabelWidth), 1)
            let step = max(Int(ceil(Double(ticks.count) / Double(capacity))), 1)
            let visibleTicks = ticks.enumerated().filter { $0.offset % step == 0 }.map(\.element)
            ForEach(visibleTicks, id: \.self) { tick in
                let x = tick.timeIntervalSince(start) / end.timeIntervalSince(start) * proxy.size.width
                Text(Self.clockFormatter.string(from: tick))
                    .font(.holoTinyLabel)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .position(x: min(max(x, tickLabelWidth / 2), max(proxy.size.width - tickLabelWidth / 2, tickLabelWidth / 2)), y: proxy.size.height / 2)
            }
        }
        .frame(height: tickRowHeight)
        .accessibilityHidden(true)
    }

    /// 长窗口每两小时一个整点；从实际整点取值，避免样本的秒数带偏刻度。
    static func tickTimes(windowStart: Date, windowEnd: Date, calendar: Calendar = .current) -> [Date] {
        guard windowEnd.timeIntervalSince(windowStart) >= 2 * 3600,
              let hour = calendar.dateInterval(of: .hour, for: windowStart),
              let firstTick = calendar.date(byAdding: .hour, value: 1, to: hour.start) else { return [] }
        var tick = firstTick
        var result: [Date] = []
        let step = windowEnd.timeIntervalSince(windowStart) >= 5 * 3600 ? 2 : 1
        while tick < windowEnd {
            result.append(tick)
            guard let next = calendar.date(byAdding: .hour, value: step, to: tick) else { break }
            tick = next
        }
        return result
    }

    private var legendRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HoloSpacing.md) { legendItems }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: HoloSpacing.sm) { legendItems }
        }
    }

    @ViewBuilder
    private var legendItems: some View {
        legendDot(stage: .asleepDeep, label: "深睡")
        legendDot(stage: .asleepCore, label: "核心")
        legendDot(stage: .asleepREM, label: "快速眼动")
        legendDot(stage: .awake, label: "清醒")
        legendDot(stage: .inBedAwake, label: "在床")
        if timeline.segments.contains(where: { $0.stage == .asleepUnspecified }) {
            legendDot(stage: .asleepUnspecified, label: "未分期")
        }
    }

    private func legendDot(stage: HealthSleepSegment.Stage, label: String) -> some View {
        HStack(spacing: HoloSpacing.xs) {
            Circle().fill(Self.color(for: stage)).frame(width: 7, height: 7)
            Text(LocalizedStringKey(label))
                .font(.holoTinyLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statsRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  alignment: .leading, spacing: HoloSpacing.md) {
            statItem(value: detail.interruptionCount.map { String(localized: "\($0) 次") } ?? String(localized: "未记录"), label: "夜间清醒 ≥2 分钟")
            statItem(value: detail.remEpisodes.map { String(localized: "\($0) 段") } ?? String(localized: "未记录"), label: "快速眼动片段")
            statItem(value: detail.sleepOnsetLatencyMinutes.map { String(localized: "\(Int($0)) 分钟") } ?? String(localized: "未记录"), label: "入睡耗时")
            statItem(value: Self.deepFocusText(detail.deepFrontLoadPercent), label: "深睡集中")
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text(value)
                .holoText(.body)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(label))
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 标题与说明使用同一组边界：<40 后半夜，40..<60 均匀，≥60 前半夜。
    static func deepFocusText(_ ratio: Double?) -> String {
        guard let ratio else { return String(localized: "未记录") }
        return ratio >= 60 ? String(localized: "前半夜") : (ratio < 40 ? String(localized: "后半夜") : String(localized: "均匀"))
    }

    @ViewBuilder
    private var napRow: some View {
        if let count = detail.napCount, count > 0 {
            let duration = Self.napDurationFormatter.string(from: (detail.napHours ?? 0) * 3600) ?? ""
            Text(String(format: String(localized: "白天另有小睡 %lld 次 · 约 %@，未计入上图"), count, duration))
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(Self.structureSummary(detail: detail))
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
            Text("片段数不等于睡眠周期；单晚分期仅供参考，建议结合多晚趋势观察。")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 描述观测事实，不凭单晚片段数或分布诊断睡眠质量。
    static func structureSummary(detail: HealthSleepDetail) -> String {
        var parts: [String] = []
        if let front = detail.deepFrontLoadPercent {
            if front >= 60 { parts.append(String(localized: "深睡主要分布在前半夜")) }
            else if front < 40 { parts.append(String(localized: "深睡主要分布在后半夜")) }
            else { parts.append(String(localized: "深睡在前后半夜分布较均匀")) }
        }
        if let episodes = detail.remEpisodes {
            parts.append(String(localized: "记录到快速眼动 \(episodes) 个片段"))
        }
        if let latency = detail.sleepOnsetLatencyMinutes {
            parts.append(String(localized: "上床至入睡约 \(Int(latency)) 分钟"))
        }
        if parts.isEmpty { parts.append(String(localized: "结构数据不足，参考时长与作息趋势即可")) }
        return parts.joined(separator: "；") + "。"
    }

    /// 只合并相接或重叠的同阶段记录，短段和未记录的间隙按真实时间保留。
    static func displaySegments(from segments: [HealthSleepSegment]) -> [HealthSleepSegment] {
        var result: [HealthSleepSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.stage == segment.stage, segment.start <= last.end {
                result[result.count - 1] = HealthSleepSegment(stage: last.stage, start: last.start, end: max(last.end, segment.end))
            } else { result.append(segment) }
        }
        return result
    }

    static func color(for stage: HealthSleepSegment.Stage) -> Color {
        switch stage {
        case .asleepDeep: return .holoChart1
        case .asleepCore: return .holoChart7
        case .asleepUnspecified: return .holoToolInfo.opacity(0.45)
        case .asleepREM: return .holoChart8
        case .awake: return .holoToolTextSecondary.opacity(0.65)
        case .inBedAwake: return .holoToolTextSecondary.opacity(0.26)
        }
    }
}
