//
//  SleepStagesCard.swift
//  Holo
//
//  睡眠阶段卡片：深度睡眠为主展示，核心睡眠 / 快速眼动 / 清醒为次要行
//

import SwiftUI

// MARK: - SleepStagesCard

struct SleepStagesCard: View {
    let detail: HealthSleepDetail

    private struct StageItem: Identifiable {
        let id: String
        let name: String
        let hours: Double
        let color: Color
    }

    /// 深度睡眠单独作为主视觉，其余阶段按比例条展示
    private var deepSleepHours: Double? {
        detail.deepHours
    }

    private var secondaryStages: [StageItem] {
        var items: [StageItem] = []
        if let core = detail.coreHours {
            items.append(StageItem(id: "core", name: "核心睡眠", hours: core, color: .holoChart7))
        }
        if let rem = detail.remHours {
            items.append(StageItem(id: "rem", name: "快速眼动", hours: rem, color: .holoChart8))
        }
        if let awake = detail.awakeHours {
            items.append(StageItem(id: "awake", name: "清醒", hours: awake, color: .holoTextSecondary))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("睡眠阶段")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            if let deep = deepSleepHours {
                deepSleepHero(hours: deep)
            }

            ForEach(secondaryStages) { stage in
                stageRow(stage)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    /// 深度睡眠主视觉：大数值 + 占总睡眠比例
    private func deepSleepHero(hours: Double) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Text("深")
                .font(.holoLabel)
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Color.holoChart1)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("深度睡眠")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextPrimary)

                Text(proportionText(for: hours))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: 0)

            Text(Self.formatHours(hours))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.holoChart1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoChart1.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 次要阶段行：色点 + 名称 + 占比条 + 时长
    private func stageRow(_ stage: StageItem) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Circle()
                .fill(stage.color)
                .frame(width: 8, height: 8)

            Text(stage.name)
                .font(.holoLabel)
                .foregroundColor(.holoTextPrimary)

            Spacer(minLength: HoloSpacing.sm)

            proportionBar(for: stage)

            Text(Self.formatHours(stage.hours))
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func proportionBar(for stage: StageItem) -> some View {
        GeometryReader { proxy in
            let ratio = proportion(of: stage.hours)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoDivider)
                Capsule()
                    .fill(stage.color)
                    .frame(width: proxy.size.width * ratio)
            }
        }
        .frame(width: 72, height: 6)
    }

    /// 阶段时长占总睡眠时长的比例（清醒时间也按总睡眠归一，避免超过 100%）
    private func proportion(of hours: Double) -> CGFloat {
        guard detail.totalHours > 0 else { return 0 }
        return CGFloat(min(max(hours / detail.totalHours, 0), 1))
    }

    private func proportionText(for hours: Double) -> String {
        guard detail.totalHours > 0 else { return "占总睡眠 --" }
        let percent = Int((hours / detail.totalHours * 100).rounded())
        return "占总睡眠 \(percent)%"
    }

    /// 小时数格式化为中文时长，如 1小时23分 / 45分钟
    static func formatHours(_ hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        let hourPart = totalMinutes / 60
        let minutePart = totalMinutes % 60
        if hourPart > 0, minutePart > 0 {
            return "\(hourPart)小时\(minutePart)分"
        }
        if hourPart > 0 {
            return "\(hourPart)小时"
        }
        return "\(minutePart)分钟"
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
    .background(Color.holoBackground)
}
