//
//  VitalsView.swift
//  Holo
//
//  身体状态页（二期，方案 A：主看板窄入口进入）：
//  静息心率 / 心率变异性 / 夜间呼吸频率的 30 天趋势 + 个人基线对比。
//  口径：全部与用户自己的 30 天基线比（不与人群参考比）；趋势观察，非医疗建议。
//  数据依赖 Apple Watch；未授权时给重新授权入口。
//

import SwiftUI
import Charts

// MARK: - VitalsView

struct VitalsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repository = HealthRepository.shared
    @State private var vitals: [DailyVitals] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 60)
                    } else if hasAnyData {
                        vitalsContent
                    } else {
                        emptyState
                    }
                }
                .padding(HoloSpacing.page)
                .holoContentColumn(paintsBackground: false)
            }
        }
        .background(Color.holoToolBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            dismiss()
        }
        .task {
            await load()
        }
    }

    private var hasAnyData: Bool {
        vitals.contains { $0.restingHeartRate != nil || $0.heartRateVariability != nil || $0.respiratoryRate != nil }
    }

    // MARK: - 头部（对齐 HealthDetailView 模式）

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .top, spacing: HoloSpacing.md) {
                HoloIconButton(systemName: "chevron.left", title: "返回", showsSurface: true) {
                    dismiss()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("身体状态")
                        .holoText(.pageTitle)
                        .foregroundColor(.holoToolText)
                    Text("与你自己的 30 天基线比较")
                        .holoText(.supporting)
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - 三项体征

    private var vitalsContent: some View {
        VStack(spacing: HoloSpacing.md) {
            vitalRow(
                title: String(localized: "静息心率"),
                subtitle: String(localized: "30 天趋势 vs 基线 \(baselineText(\.restingHeartRate))"),
                unit: "bpm",
                values: series(\.restingHeartRate)
            )
            vitalRow(
                title: String(localized: "心率变异性"),
                subtitle: String(localized: "HRV · 压力与恢复"),
                unit: "ms",
                values: series(\.heartRateVariability)
            )
            vitalRow(
                title: String(localized: "夜间呼吸频率"),
                subtitle: String(localized: "睡眠期均值 vs 基线 \(baselineText(\.respiratoryRate))"),
                unit: String(localized: "次/分"),
                values: series(\.respiratoryRate)
            )

            Text("心率偏高与 HRV 偏低同时出现，常与疲劳或恢复不足相关，可适当降低训练强度。均与自己的基线比较；趋势观察，非医疗建议。数据来自 Apple Watch。")
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HoloSpacing.md)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    private func vitalRow(title: String, subtitle: String, unit: String, values: [(date: Date, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                Text(title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Spacer(minLength: HoloSpacing.sm)
                if let latest = values.last {
                    Text("\(String(format: "%.0f", latest.value)) \(unit)")
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.holoToolText)
                        .layoutPriority(1)
                } else {
                    Text("—")
                        .holoText(.body)
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            Text(subtitle)
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let latest = values.last {
                VitalsTrendChart(values: values, unit: unit, baseline: baseline(values))
                deviationText(latest: latest.value, baseline: baseline(values))
                    .holoText(.metadata)
            } else {
                Text("无数据")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func deviationText(latest: Double, baseline: Double?) -> some View {
        Group {
            if let baseline {
                let delta = latest - baseline
                let magnitude = abs(delta) / max(baseline, 0.001)
                if magnitude < Self.baselineBandRatio {
                    Text("基线附近").foregroundColor(.holoToolTextSecondary)
                } else if delta > 0 {
                    Text("高于基线 \(String(format: "%.1f", delta)) ↗").foregroundColor(.holoChart4)
                } else {
                    Text("低于基线 \(String(format: "%.1f", -delta)) ↘").foregroundColor(.holoChart4)
                }
            } else {
                Text("基线不足").foregroundColor(.holoToolTextSecondary)
            }
        }
    }

    // MARK: - 数据整形

    private func series(_ keyPath: KeyPath<DailyVitals, Double?>) -> [(date: Date, value: Double)] {
        vitals.compactMap { row in
            guard let value = row[keyPath: keyPath] else { return nil }
            return (row.date, value)
        }
    }

    private func baseline(_ values: [(date: Date, value: Double)]) -> Double? {
        guard values.count >= Self.baselineMinPoints else { return nil }
        return values.reduce(0.0) { $0 + $1.value } / Double(values.count)
    }

    private func baselineText(_ keyPath: KeyPath<DailyVitals, Double?>) -> String {
        guard let baseline = baseline(series(keyPath)) else { return "—" }
        return String(format: "%.0f", baseline)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "applewatch")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))

            Text("暂无体征数据")
                .holoText(.body)
                .foregroundColor(.holoToolText)

            Text("静息心率、心率变异性、夜间呼吸频率需要佩戴 Apple Watch 记录。已佩戴但仍为空，可尝试重新授权健康数据读取。")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                repository.requestAuthorization()
            } label: {
                Text("重新授权健康数据")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
        .padding(.top, 40)
        .padding(.horizontal, HoloSpacing.xl)
    }

    private func load() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(HealthThresholds.vitalsWindowDays - 1), to: today) ?? today
        vitals = await repository.fetchVitalsRange(from: start, to: today)
        #if DEBUG && targetEnvironment(simulator)
        // 仅隔离截图/验收模式裁剪模拟数据，验证空态与最稀疏状态；不写健康库。
        let env = ProcessInfo.processInfo.environment
        if env["HOLO_APP_STORE_SCREENSHOT_MODE"] == "1",
           let text = env["HOLO_POLISH_VITALS_POINTS"], let count = Int(text), (0...3).contains(count) {
            vitals = Array(vitals.suffix(count))
        }
        #endif
        isLoading = false
    }

    /// 基线附近的判定带宽（±3% 内视为「基线附近」）
    private static let baselineBandRatio = 0.03
    /// 计算基线所需的最少样本点（少于 4 点不足以成线）
    private static let baselineMinPoints = 4
}

#Preview {
    NavigationStack { VitalsView() }
}
