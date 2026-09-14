//
//  SleepTimelineCard.swift
//  Holo
//
//  整晚睡眠时间轴（三期重设计）：只画「主睡眠」（小睡由 HealthSleepSessionSplitter
//  切分、另行一行带过），条带按真实时间比例定位、无样本处留白；两端标注入睡/起床
//  时刻，整点刻度、四色图例、统计行与结构解读。
//  阶段色与 SleepStagesCard 一致（蓝=深睡、粉=核心、黄=REM、灰=清醒、浅灰=在床）。
//

import SwiftUI

// MARK: - SleepTimelineCard

struct SleepTimelineCard: View {
    let timeline: HealthSleepTimeline
    let detail: HealthSleepDetail

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 小睡行时长文案（系统本地化："1小时20分" / "1h 20m"）
    private static let napDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()

    private var nightSpan: TimeInterval? {
        guard let start = timeline.nightStart, let end = timeline.nightEnd else { return nil }
        return end.timeIntervalSince(start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("整晚睡眠时间轴")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            if let span = nightSpan, span > 0 {
                anchorRow
                timelineBar(span: span)
                tickRow(span: span)
                legendRow
                statsRow
                napRow
                readout
            } else {
                Text("暂无时间轴数据")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: - 时刻锚点行（入睡 / 起床）

    private var anchorRow: some View {
        HStack(alignment: .top) {
            anchor(value: detail.bedtime ?? timeline.nightStart, label: "入睡")
            Spacer()
            anchor(value: detail.wakeTime ?? timeline.nightEnd, label: "起床")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func anchor(value: Date?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map { Self.clockFormatter.string(from: $0) } ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
            Text(LocalizedStringKey(label))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - 时间轴主体（真实比例定位，空隙留白）

    private func timelineBar(span: TimeInterval) -> some View {
        let nightStart = timeline.nightStart!
        let segments = Self.displaySegments(from: timeline.segments)
        return GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoNestedCardBackground)
                    .frame(maxWidth: .infinity)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let ratio = segment.start.timeIntervalSince(nightStart) / span
                    let widthRatio = segment.duration / span
                    Rectangle()
                        .fill(Self.color(for: segment.stage))
                        .frame(width: min(max(widthRatio * width + 0.5, 1), width))
                        .offset(x: ratio * width)
                }
            }
            .frame(height: 24)
            .clipShape(Capsule())
            .position(x: width / 2, y: proxy.size.height / 2)
        }
        .frame(height: 28)
    }

    // MARK: - 整点刻度

    private func tickRow(span: TimeInterval) -> some View {
        let nightStart = timeline.nightStart!
        let ticks = Self.tickTimes(windowStart: nightStart, windowEnd: timeline.nightEnd ?? nightStart)
        return GeometryReader { proxy in
            let width = proxy.size.width
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let rawX = tick.timeIntervalSince(nightStart) / span * width
                Text(Self.clockFormatter.string(from: tick))
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .position(x: min(max(rawX, 16), width - 16), y: proxy.size.height / 2)
            }
        }
        .frame(height: 14)
    }

    /// 窗口内整点刻度：跨度 ≥5 小时每 2 小时一个，否则每 1 小时；从窗口起点后的第一个整点起。
    static func tickTimes(windowStart: Date, windowEnd: Date, calendar: Calendar = .current) -> [Date] {
        guard windowEnd.timeIntervalSince(windowStart) >= 2 * 3600 else { return [] }
        let minute = calendar.component(.minute, from: windowStart)
        var tick = windowStart.addingTimeInterval(TimeInterval(60 - minute) * 60)
        var result: [Date] = []
        let step: TimeInterval = windowEnd.timeIntervalSince(windowStart) >= 5 * 3600 ? 7200 : 3600
        while tick < windowEnd {
            result.append(tick)
            tick = tick.addingTimeInterval(step)
        }
        return result
    }

    // MARK: - 图例

    private var legendRow: some View {
        HStack(spacing: 14) {
            legendDot(color: Self.color(for: .asleepDeep), label: "深睡")
            legendDot(color: Self.color(for: .asleepCore), label: "核心")
            legendDot(color: Self.color(for: .asleepREM), label: "REM")
            legendDot(color: Self.color(for: .awake), label: "清醒")
            legendDot(color: Self.color(for: .inBedAwake), label: "在床")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(LocalizedStringKey(label))
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - 统计行（入睡/起床已在锚点行，不重复）

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: detail.interruptionCount.map { String(localized: "\($0) 次") } ?? "—", label: "夜醒")
            statItem(value: detail.remEpisodes.map { String(localized: "\($0) 段") } ?? "—", label: "REM")
            statItem(value: detail.sleepOnsetLatencyMinutes.map { String(localized: "\(Int($0)) 分") } ?? "—", label: "入睡耗时")
            statItem(value: deepFocusText, label: "深睡集中")
        }
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.holoBorder)
                .frame(height: 1)
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(LocalizedStringKey(label))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 深睡集中：nil 才是「无数据」；0%（深睡全在后半夜）是合法值，与解读文案同口径。
    private var deepFocusText: String {
        guard let ratio = detail.deepFrontLoadPercent else { return "—" }
        return ratio >= 60 ? String(localized: "前半夜") : (ratio < 40 ? String(localized: "后半夜") : String(localized: "均匀"))
    }

    // MARK: - 小睡行

    @ViewBuilder
    private var napRow: some View {
        if let napCount = detail.napCount, napCount > 0 {
            let duration = Self.napDurationFormatter.string(from: (detail.napHours ?? 0) * 3600) ?? ""
            Text(String(format: String(localized: "白天另有小睡 %lld 次 · 约 %@，未计入上图"), napCount, duration))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoNestedCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - 结构解读

    private var readout: some View {
        Text(Self.structureSummary(detail: detail))
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

    /// 由结构特征生成一句话解读（趋势观察口径，不做医学判断）。
    /// 各片段独立本地化后按句拼接；多语言下的连接符沿用中文分号。
    static func structureSummary(detail: HealthSleepDetail) -> String {
        var parts: [String] = []
        if let front = detail.deepFrontLoadPercent {
            parts.append(front >= 60
                ? String(localized: "深睡集中在前半夜，符合正常节律")
                : String(localized: "深睡分布偏后半夜，入睡质量值得观察"))
        }
        if let episodes = detail.remEpisodes {
            let remTrend = (4...6).contains(episodes)
                ? String(localized: "REM \(episodes) 段，节律正常")
                : String(localized: "REM \(episodes) 段")
            parts.append(remTrend)
        }
        if let latency = detail.sleepOnsetLatencyMinutes {
            if latency <= 20 {
                parts.append(String(localized: "入睡较快（\(Int(latency)) 分钟）"))
            } else if latency >= 45 {
                parts.append(String(localized: "入睡偏慢（\(Int(latency)) 分钟）"))
            }
        }
        if parts.isEmpty {
            parts.append(String(localized: "结构数据不足，参考时长与作息趋势即可"))
        }
        return parts.joined(separator: "；") + String(localized: "。单晚分期精度有限，建议看多晚趋势。")
    }

    // MARK: - 显示段纯函数

    /// 显示用分段：<40 秒的清醒段并入底色不画；相邻同阶段缝隙 <2 分钟缝合
    /// （消灭分钟级样本碎片条纹）。
    static func displaySegments(from segments: [HealthSleepSegment]) -> [HealthSleepSegment] {
        let filtered = segments.filter { !($0.stage == .awake && $0.duration < 40) }
        var result: [HealthSleepSegment] = []
        for segment in filtered {
            if let last = result.last, last.stage == segment.stage,
               segment.start.timeIntervalSince(last.end) < 120 {
                result[result.count - 1] = HealthSleepSegment(
                    stage: last.stage, start: last.start, end: segment.end
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }

    static func color(for stage: HealthSleepSegment.Stage) -> Color {
        switch stage {
        case .asleepDeep: return .holoChart1
        case .asleepCore, .asleepUnspecified: return .holoChart7
        case .asleepREM: return .holoChart8
        case .awake: return .holoTextSecondary.opacity(0.4)
        case .inBedAwake: return .holoTextSecondary.opacity(0.26)
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let wakeDay = calendar.startOfDay(for: Date())
    let bed = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: calendar.date(byAdding: .day, value: -1, to: wakeDay)!)!
    func segment(_ stage: HealthSleepSegment.Stage, _ start: Double, _ end: Double) -> HealthSleepSegment {
        HealthSleepSegment(stage: stage, start: bed.addingTimeInterval(start * 60), end: bed.addingTimeInterval(end * 60))
    }
    let timeline = HealthSleepTimeline(wakeDay: wakeDay, segments: [
        segment(.inBedAwake, 0, 17), segment(.asleepDeep, 17, 61), segment(.asleepCore, 61, 105),
        segment(.asleepDeep, 105, 148), segment(.asleepREM, 148, 160), segment(.awake, 160, 172),
        segment(.asleepCore, 172, 215), segment(.asleepREM, 236, 258), segment(.asleepCore, 258, 340),
        segment(.awake, 340, 351), segment(.asleepREM, 351, 385), segment(.asleepCore, 385, 467),
        segment(.awake, 467, 479), segment(.inBedAwake, 479, 525)
    ], hasStageData: true)
    let detail = HealthSleepDetail(
        date: wakeDay, totalHours: 8.1, coreHours: 3.6, deepHours: 1.8, remHours: 1.6,
        awakeHours: 0.4, inBedHours: 8.8, bedtime: bed.addingTimeInterval(17 * 60),
        wakeTime: bed.addingTimeInterval(525 * 60), interruptionCount: 2,
        remEpisodes: 4, remLatencyMinutes: 131, deepFrontLoadPercent: 76, sleepOnsetLatencyMinutes: 17,
        napCount: 1, napHours: 1.3
    )
    return SleepTimelineCard(timeline: timeline, detail: detail)
        .padding()
        .background(Color.holoBackground)
}
