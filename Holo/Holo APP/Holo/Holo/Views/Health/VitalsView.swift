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
    @StateObject private var repository = HealthRepository.shared
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
                .padding(HoloSpacing.md)
                .holoContentColumn(paintsBackground: false)
            }
        }
        .background(Color.holoBackground)
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
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text("身体状态")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)
                    Text("与你自己的 30 天基线比较")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - 三项体征

    private var vitalsContent: some View {
        VStack(spacing: HoloSpacing.md) {
            vitalRow(
                title: "静息心率",
                subtitle: "30 天趋势 vs 基线 \(baselineText(\.restingHeartRate))",
                unit: "bpm",
                values: series(\.restingHeartRate)
            )
            vitalRow(
                title: "心率变异性",
                subtitle: "HRV · 压力与恢复",
                unit: "ms",
                values: series(\.heartRateVariability)
            )
            vitalRow(
                title: "夜间呼吸频率",
                subtitle: "睡眠期均值 vs 基线 \(baselineText(\.respiratoryRate))",
                unit: "次/分",
                values: series(\.respiratoryRate)
            )

            Text("心率偏高与 HRV 偏低同时出现，常与疲劳或恢复不足相关，可适当降低训练强度。均与自己的基线比较；趋势观察，非医疗建议。数据来自 Apple Watch。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HoloSpacing.md)
                .background(Color.holoNestedCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    private func vitalRow(title: String, subtitle: String, unit: String, values: [(date: Date, value: Double)]) -> some View {
        HStack(spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextPrimary)
                Text(subtitle)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
            .frame(width: 118, alignment: .leading)

            sparkline(values: values)

            VStack(alignment: .trailing, spacing: 2) {
                if let latest = values.last {
                    Text(String(format: "%.0f", latest.value))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                    deviationText(latest: latest.value, baseline: baseline(values))
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("—")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                    Text("无数据")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private func sparkline(values: [(date: Date, value: Double)]) -> some View {
        Chart(values, id: \.date) { point in
            LineMark(
                x: .value("日期", point.date, unit: .day),
                y: .value("值", point.value)
            )
            .foregroundStyle(Color.holoChart4.gradient)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // 显式固定 y 域，与基线虚线的 overlay 换算共用同一 domain，保证虚线位置成比例
        .chartYScale(domain: chartDomain(values))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay(alignment: .center) {
            if let baseline = baseline(values) {
                GeometryReader { proxy in
                    // 基线参考虚线：按值域换算 y 位置
                    let domain = chartDomain(values)
                    let ratio = (baseline - domain.lowerBound) / max(domain.upperBound - domain.lowerBound, 0.001)
                    let y = proxy.size.height * (1 - ratio)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(Color.holoTextSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private func deviationText(latest: Double, baseline: Double?) -> some View {
        Group {
            if let baseline {
                let delta = latest - baseline
                let magnitude = abs(delta) / max(baseline, 0.001)
                if magnitude < 0.03 {
                    Text("基线附近").foregroundColor(.holoTextSecondary)
                } else if delta > 0 {
                    Text("高于基线 \(String(format: "%.1f", delta)) ↗").foregroundColor(.holoChart4)
                } else {
                    Text("低于基线 \(String(format: "%.1f", -delta)) ↘").foregroundColor(.holoChart4)
                }
            } else {
                Text("基线不足").foregroundColor(.holoTextSecondary)
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
        guard values.count >= 4 else { return nil }
        return values.reduce(0.0) { $0 + $1.value } / Double(values.count)
    }

    private func baselineText(_ keyPath: KeyPath<DailyVitals, Double?>) -> String {
        guard let baseline = baseline(series(keyPath)) else { return "—" }
        return String(format: "%.0f", baseline)
    }

    private func chartDomain(_ values: [(date: Date, value: Double)]) -> ClosedRange<Double> {
        let numbers = values.map(\.value)
        let minVal = numbers.min() ?? 0
        let maxVal = numbers.max() ?? 1
        let padding = max((maxVal - minVal) * 0.15, 0.5)
        return (minVal - padding)...(maxVal + padding)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "applewatch")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无体征数据")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Text("静息心率、心率变异性、夜间呼吸频率需要佩戴 Apple Watch 记录。已佩戴但仍为空，可尝试重新授权健康数据读取。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                repository.requestAuthorization()
            } label: {
                Text("重新授权健康数据")
                    .font(.holoLabel)
                    .foregroundColor(.white)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, 10)
                    .background(Color.holoChart4)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 40)
        .padding(.horizontal, HoloSpacing.xl)
    }

    private func load() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        vitals = await repository.fetchVitalsRange(from: start, to: today)
        isLoading = false
    }
}

#Preview {
    NavigationStack { VitalsView() }
}
