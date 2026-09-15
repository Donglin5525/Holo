//
//  WorkoutSessionDetailSheet.swift
//  Holo
//
//  单次运动明细弹层：时长/距离/能量/心率统计 + 心率曲线 + 五区间分布 + 配速。
//  心率曲线与区间懒加载（仅打开弹层时按会话起止拉心率样本）；
//  区间按最大心率百分比划分（220−年龄估算，读不到生日回退 190 并标注「估算」）。
//

import SwiftUI
import Charts

// MARK: - WorkoutSessionDetailSheet

struct WorkoutSessionDetailSheet: View {
    let session: WorkoutSessionData

    @StateObject private var repository = HealthRepository.shared
    @State private var heartDetail: WorkoutHeartDetail?
    @State private var isLoadingHeart = true
    @Environment(\.dismiss) private var dismiss

    /// 五区间标签与配色（Z1 热身 → Z5 极限，强度渐强）
    private static let zoneMeta: [(label: String, color: Color)] = [
        (String(localized: "Z1 热身"), .holoChart3),
        (String(localized: "Z2 燃脂"), .holoChart8),
        (String(localized: "Z3 有氧"), .holoChart2),
        (String(localized: "Z4 阈值"), .holoChart4),
        (String(localized: "Z5 极限"), .holoChart11)
    ]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMddHHmm")
        return formatter
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                header

                statGrid

                heartSection

                paceSection

                sourceFooter
            }
            .padding(HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .task {
            heartDetail = await repository.fetchWorkoutHeartDetail(session: session)
            isLoadingHeart = false
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: session.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.holoChart3)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.localizedName)
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)

                    Text(Self.timeFormatter.string(from: session.start))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 统计格（2×3）

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: HoloSpacing.sm) {
            statCell(title: String(localized: "时长"), value: String(localized: "\(Int(session.minutes.rounded())) 分钟"))
            statCell(title: String(localized: "距离"), value: distanceText)
            statCell(title: String(localized: "能量"), value: kcalText)
            statCell(title: String(localized: "平均心率"), value: heartText(session.averageHeartRate))
            statCell(title: String(localized: "最高心率"), value: heartText(session.maxHeartRate))
            statCell(title: String(localized: "配速"), value: paceText)
        }
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    private var distanceText: String {
        guard let meters = session.distanceMeters else { return "—" }
        return String(localized: "\(String(format: "%.1f", meters / 1000)) 公里")
    }

    private var kcalText: String {
        guard let kcal = session.kilocalories else { return "—" }
        return String(localized: "\(Int(kcal.rounded())) 千卡")
    }

    private var paceText: String {
        guard let pace = WorkoutPaceFormatter.paceText(secondsPerKm: session.paceSecondsPerKm) else { return "—" }
        return String(localized: "\(pace) /公里")
    }

    private func heartText(_ bpm: Double?) -> String {
        guard let bpm else { return "—" }
        return String(localized: "\(Int(bpm.rounded())) bpm")
    }

    // MARK: - 心率曲线与区间

    private var heartSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("心率")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if isLoadingHeart {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if let heartDetail, !heartDetail.points.isEmpty {
                heartChart(heartDetail)
                zoneBar(heartDetail)
                zoneLegend(heartDetail)
                if heartDetail.isEstimatedMaxHeartRate {
                    Text("最大心率按 190 估算（健康资料中读不到生日），区间仅供参考。")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            } else if isLoadingHeart {
                Text("正在读取心率…")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text("这次运动没有心率数据。心率曲线与区间通常需要 Apple Watch 记录。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private func heartChart(_ detail: WorkoutHeartDetail) -> some View {
        Chart(detail.points) { point in
            LineMark(
                x: .value("时间", point.date),
                y: .value("心率", point.bpm)
            )
            .foregroundStyle(Color.holoChart4.gradient)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

            if let average = session.averageHeartRate {
                RuleMark(y: .value("平均心率", average))
                    .foregroundStyle(Color.holoTextSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.system(size: 9))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel {
                    if let bpm = value.as(Double.self) {
                        Text("\(Int(bpm))")
                            .font(.system(size: 9))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .frame(height: 120)
    }

    /// 五区间停留时长比例条（总量为运动时长）
    private func zoneBar(_ detail: WorkoutHeartDetail) -> some View {
        let total = detail.zoneMinutes.reduce(0, +)
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(detail.zoneMinutes.enumerated()), id: \.offset) { index, minutes in
                    let ratio = total > 0 ? minutes / total : 0
                    Capsule()
                        .fill(Self.zoneMeta[index].color)
                        .frame(width: ratio > 0 ? max(proxy.size.width * ratio - 2, 4) : 0)
                }
            }
        }
        .frame(height: 10)
    }

    private func zoneLegend(_ detail: WorkoutHeartDetail) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(Array(detail.zoneMinutes.enumerated()), id: \.offset) { index, minutes in
                HStack(spacing: HoloSpacing.sm) {
                    Circle()
                        .fill(Self.zoneMeta[index].color)
                        .frame(width: 8, height: 8)

                    Text(Self.zoneMeta[index].label)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text(SleepStagesCard.formatHours(minutes / 60))
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoNestedCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 配速解读（仅有距离的运动显示）

    @ViewBuilder
    private var paceSection: some View {
        if let pace = WorkoutPaceFormatter.paceText(secondsPerKm: session.paceSecondsPerKm) {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("配速")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                HStack {
                    Text(String(localized: "\(pace) /公里"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.holoChart3)
                    Spacer()
                }

                Text("平均配速 = 运动时长 ÷ 距离。与自己近期配速对比才有意义，单次受地形与状态影响波动正常。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(HoloSpacing.md)
            .holoCard()
        }
    }

    private var sourceFooter: some View {
        Text(String(localized: "数据来源：\(session.sourceName)"))
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextSecondary.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: Date())
    let session = WorkoutSessionData(
        id: UUID(), start: day.addingTimeInterval(8 * 3600), end: day.addingTimeInterval(8 * 3600 + 42 * 60),
        activityTypeRaw: 52, typeName: "跑步",
        distanceMeters: 6800, kilocalories: 380, averageHeartRate: 152, maxHeartRate: 171, sourceName: "Apple Watch"
    )
    return WorkoutSessionDetailSheet(session: session)
}
