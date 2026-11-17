//
//  HealthNightVitalsCard.swift
//  Holo
//
//  一晚的睡眠体征卡（健康分析方案第三步）：心率/呼吸/HRV 按主睡眠可信
//  睡着区间匹配。每项独立判定覆盖——达标给中位数，少量样本标注「观测点」，
//  无样本如实缺失；区间外样本（日间呼吸、睡前 HRV）不进入统计。
//

import SwiftUI

struct HealthNightVitalsCard: View {
    let vitals: HealthNightVitals

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("这一晚的体征")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                Spacer()
                Text("按实际睡着区间统计")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }

            vitalRow(
                icon: "heart.fill",
                title: String(localized: "睡眠心率"),
                unit: String(localized: "次/分"),
                metric: vitals.heartRate
            )
            vitalRow(
                icon: "lungs.fill",
                title: String(localized: "睡眠呼吸"),
                unit: String(localized: "次/分"),
                metric: vitals.respiratory
            )
            vitalRow(
                icon: "waveform.path.ecg",
                title: String(localized: "睡眠 HRV"),
                unit: "ms",
                metric: vitals.heartRateVariability
            )
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func vitalRow(icon: String, title: String, unit: String, metric: HealthNightMetricVitals) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoToolAction)
                .frame(width: 28, height: 28)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(coverageText(metric))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            if let median = metric.median {
                (Text("\(Int(median.rounded()))")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.holoToolText)
                    + Text(" \(unit)").font(.holoTinyLabel).foregroundColor(.holoToolTextSecondary))
                    .monospacedDigit()
            } else {
                Text(medianPlaceholder(metric.coverage))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
    }

    /// 覆盖说明：采样点数 + 状态（观测点/无样本），详情可核对实际采样
    private func coverageText(_ metric: HealthNightMetricVitals) -> String {
        switch metric.coverage {
        case .sufficient:
            return String(localized: "\(metric.samples.count) 个采样 · 中位数")
        case .observed:
            return String(localized: "\(metric.samples.count) 个采样 · 样本不足，作观测点")
        case .none:
            return String(localized: "这一晚无入睡区间内样本")
        }
    }

    private func medianPlaceholder(_ coverage: HealthNightMetricVitals.Coverage) -> String {
        switch coverage {
        case .sufficient: return ""
        case .observed: return String(localized: "观测点")
        case .none: return String(localized: "无样本")
        }
    }
}
