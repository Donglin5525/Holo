// 睡眠阶段：名称与时长同一基线，比例条独占一行；缺失值保留「未记录」。
import SwiftUI

struct SleepStagesCard: View {
    let detail: HealthSleepDetail
    @ScaledMetric(relativeTo: .caption) private var percentageColumnWidth: CGFloat = 44

    private struct StageItem: Identifiable {
        let id: String
        let name: String
        let hours: Double?
        let color: Color
    }

    private var stages: [StageItem] {
        [StageItem(id: "core", name: String(localized: "核心睡眠"), hours: detail.coreHours, color: .holoChart7),
         StageItem(id: "deep", name: String(localized: "深度睡眠"), hours: detail.deepHours, color: .holoChart1),
         StageItem(id: "rem", name: String(localized: "快速眼动（REM）"), hours: detail.remHours, color: .holoChart8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("睡眠阶段")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolText)
                Text(detail.napCount.map { $0 > 0 } == true ? "按总睡眠时长计算，含小睡" : "各阶段占总睡眠时长的比例")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }

            ForEach(stages) { stage in
                stageRow(stage)
            }

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Divider().overlay(Color.holoToolBorder)
                HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                    Circle().fill(Color.holoToolTextSecondary).frame(width: 8, height: 8)
                    Text("清醒")
                        .holoText(.supporting)
                    Spacer(minLength: HoloSpacing.sm)
                    Text(detail.awakeHours.map(Self.formatHours) ?? String(localized: "未记录"))
                        .holoText(.supporting)
                        .monospacedDigit()
                }
                Text("清醒不计入总睡眠时长；未记录表示没有该阶段样本。")
                    .holoText(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.holoToolTextSecondary)
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func stageRow(_ stage: StageItem) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                HStack(spacing: HoloSpacing.sm) {
                    Circle().fill(stage.color).frame(width: 8, height: 8)
                    Text(stage.name)
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: HoloSpacing.sm)
                Text(stage.hours.map(Self.formatHours) ?? String(localized: "未记录"))
                    .holoText(.supporting)
                    .fontWeight(.semibold)
                    .foregroundStyle(stage.hours == nil ? Color.holoToolTextSecondary : Color.holoToolText)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: HoloSpacing.sm) {
                let fraction = stage.hours.flatMap { detail.totalHours > 0 ? $0 / detail.totalHours : nil }
                HoloProgress(value: fraction, color: stage.color, lineWidth: 6)
                    .accessibilityHidden(true)
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .monospacedDigit()
                    .frame(width: percentageColumnWidth, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 小时数格式化为本地化时长。
    static func formatHours(_ hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        let hourPart = totalMinutes / 60
        let minutePart = totalMinutes % 60
        if hourPart > 0, minutePart > 0 {
            return String(localized: "\(hourPart)小时\(minutePart)分")
        }
        if hourPart > 0 { return String(localized: "\(hourPart)小时") }
        return String(localized: "\(minutePart)分钟")
    }
}

#Preview {
    SleepStagesCard(detail: HealthSleepDetail(
        date: Date(),
        totalHours: 7.5,
        coreHours: 3.8,
        deepHours: 1.6,
        remHours: 1.9,
        awakeHours: 0.2,
        inBedHours: 8.1,
        bedtime: nil,
        wakeTime: nil,
        interruptionCount: 1
    ))
    .padding()
    .background(Color.holoToolBackground)
}
