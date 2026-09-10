//
//  SleepTimelineCard.swift
//  Holo
//
//  整晚睡眠时间轴（二期）：一晚从入睡到起床的分段色条，按真实起止时间
//  排布深睡/核心/REM/清醒；夜醒时刻标注；底部统计行与结构解读。
//  阶段色与 SleepStagesCard 一致（蓝=深睡、粉=核心、黄=REM、灰=清醒）。
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
                timelineBar(span: span)
                statsRow
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

    // MARK: - 时间轴主体

    private func timelineBar(span: TimeInterval) -> some View {
        let nightStart = timeline.nightStart!
        return VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                ZStack(alignment: .leading) {
                    // 夜醒时刻标注（≥2 分钟的清醒段顶上标时间）；时刻过密时上下两行交错避让
                    ForEach(staggeredWakeMarks(width: width, nightStart: nightStart, span: span), id: \.id) { mark in
                        Text(mark.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoChart4)
                            .fixedSize()
                            .position(x: mark.x, y: mark.row == 0 ? 7 : 17)
                    }

                    Capsule()
                        .fill(Color.holoNestedCardBackground)
                        .frame(height: 22)
                        .position(x: width / 2, y: height / 2 + 12)

                    // 分段色条
                    HStack(spacing: 0) {
                        ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle()
                                .fill(Self.color(for: segment.stage))
                                .frame(width: max(2, segment.duration / span * width))
                        }
                    }
                    .frame(height: 22)
                    .clipShape(Capsule())
                    .position(x: width / 2, y: height / 2 + 12)
                }
            }
            .frame(height: 50)

            tickRow(span: span)
        }
    }

    private struct WakeMark {
        let start: Date
        let label: String
    }

    private struct PositionedWakeMark: Identifiable {
        let id: Int
        let label: String
        let x: CGFloat
        let row: Int
    }

    /// 夜醒标注避让：按时间序贪心放入上下两行，与同行前一个标签水平间距不足 minGap 时换行；
    /// 两行都放不下则不显示（极密集时叠字比缺字更伤可读性）。
    private func staggeredWakeMarks(width: CGFloat, nightStart: Date, span: TimeInterval) -> [PositionedWakeMark] {
        let xs = wakeMarks.map {
            min(max(offset($0.start, nightStart: nightStart, span: span) * width, 14), width - 14)
        }
        let rows = Self.wakeMarkRows(offsets: xs, minGap: 32)
        return wakeMarks.enumerated().compactMap { index, mark in
            guard let row = rows[index] else { return nil }
            return PositionedWakeMark(id: index, label: mark.label, x: xs[index], row: row)
        }
    }

    /// 纯函数：给定按时间序排列的标注 x 坐标，返回各标注行号（0=上行 1=下行，nil=放不下不显示）。
    static func wakeMarkRows(offsets: [CGFloat], minGap: CGFloat) -> [Int?] {
        var rowLastX: [CGFloat?] = [nil, nil]
        return offsets.map { x in
            let fitsRow0 = rowLastX[0].map { x - $0 >= minGap } ?? true
            let fitsRow1 = rowLastX[1].map { x - $0 >= minGap } ?? true
            let row = fitsRow0 ? 0 : (fitsRow1 ? 1 : nil)
            if let row { rowLastX[row] = x }
            return row
        }
    }

    /// 夜醒标注：≥120 秒的 awake 段（与 interruptionCount 同口径）
    private var wakeMarks: [WakeMark] {
        timeline.segments
            .filter { $0.stage == .awake && $0.duration >= 120 }
            .map { WakeMark(start: $0.start, label: Self.clockFormatter.string(from: $0.start)) }
    }

    private func offset(_ date: Date, nightStart: Date, span: TimeInterval) -> CGFloat {
        date.timeIntervalSince(nightStart) / span
    }

    private func tickRow(span: TimeInterval) -> some View {
        let nightStart = timeline.nightStart!
        let formatter = Self.clockFormatter
        return GeometryReader { proxy in
            let width = proxy.size.width
            HStack {
                Text(formatter.string(from: nightStart))
                Spacer()
                if let mid = timeline.nightStart?.addingTimeInterval(span / 2) {
                    Text(formatter.string(from: mid))
                }
                Spacer()
                Text(formatter.string(from: timeline.nightEnd ?? nightStart))
            }
            .font(.system(size: 10))
            .foregroundColor(.holoTextSecondary)
            .frame(width: width)
        }
        .frame(height: 14)
    }

    // MARK: - 统计行

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: timeText(detail.bedtime), label: "入睡")
            statItem(value: timeText(detail.wakeTime), label: "起床")
            statItem(value: detail.interruptionCount.map { "\($0) 次" } ?? "—", label: "夜醒")
            statItem(value: detail.remEpisodes.map { "\($0) 段" } ?? "—", label: "REM")
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
            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.clockFormatter.string(from: date)
    }

    private var deepFocusText: String {
        guard let ratio = detail.deepFrontLoadPercent, ratio > 0 else { return "—" }
        return ratio >= 60 ? "前半夜" : (ratio < 40 ? "后半夜" : "均匀")
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

    /// 由结构特征生成一句话解读（趋势观察口径，不做医学判断）
    static func structureSummary(detail: HealthSleepDetail) -> String {
        var parts: [String] = []
        if let front = detail.deepFrontLoadPercent {
            parts.append(front >= 60
                ? "深睡集中在前半夜，符合正常节律"
                : "深睡分布偏后半夜，入睡质量值得观察")
        }
        if let episodes = detail.remEpisodes {
            let remTrend = (4...6).contains(episodes)
                ? "REM \(episodes) 段，节律正常"
                : "REM \(episodes) 段"
            parts.append(remTrend)
        }
        if let latency = detail.sleepOnsetLatencyMinutes {
            if latency <= 20 {
                parts.append("入睡较快（\(Int(latency)) 分钟）")
            } else if latency >= 45 {
                parts.append("入睡偏慢（\(Int(latency)) 分钟）")
            }
        }
        if parts.isEmpty {
            parts.append("结构数据不足，参考时长与作息趋势即可")
        }
        return parts.joined(separator: "；") + "。单晚分期精度有限，建议看多晚趋势。"
    }

    static func color(for stage: HealthSleepSegment.Stage) -> Color {
        switch stage {
        case .asleepDeep: return .holoChart1
        case .asleepCore, .asleepUnspecified: return .holoChart7
        case .asleepREM: return .holoChart8
        case .awake: return .holoTextSecondary.opacity(0.4)
        case .inBedAwake: return .holoTextSecondary.opacity(0.18)
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
        segment(.awake, 340, 351), segment(.asleepREM, 351, 385), segment(.asleepCore, 385, 467)
    ], hasStageData: true)
    let detail = HealthSleepDetail(
        date: wakeDay, totalHours: 7.0, coreHours: 3.6, deepHours: 1.8, remHours: 1.6,
        awakeHours: 0.4, inBedHours: 7.8, bedtime: bed.addingTimeInterval(17 * 60),
        wakeTime: bed.addingTimeInterval(467 * 60), interruptionCount: 2,
        remEpisodes: 4, remLatencyMinutes: 131, deepFrontLoadPercent: 76, sleepOnsetLatencyMinutes: 17
    )
    return SleepTimelineCard(timeline: timeline, detail: detail)
        .padding()
        .background(Color.holoBackground)
}
