//
//  HealthStatusChip.swift
//  Holo
//
//  月历顶部健康保底入口（Q3）：三态——未授权 / 已连接无数据 / 已连接·本周摘要
//  复用 loadConstellationHealthState 的 HealthRepository 调用范式（健康维度不随星图消失）
//

import SwiftUI

struct HealthStatusChip: View {

    enum ChipState {
        case loading
        case unauthorized
        case noData
        case connected(summary: String)
    }

    @State private var state: ChipState = .loading

    var body: some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(iconColor)
            Text(text)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, 6)
        .background(Color.holoCardBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.holoBorder, lineWidth: 1))
        .task { await load() }
    }

    private var iconColor: Color {
        switch state {
        case .connected: return .holoChart1   // 健康蓝
        default:          return .holoTextSecondary
        }
    }

    private var text: String {
        switch state {
        case .loading:       return "健康…"
        case .unauthorized:  return "健康未授权"
        case .noData:        return "健康·本周暂无"
        case .connected(let s): return s
        }
    }

    // MARK: - 取数（复用 HealthRepository，本周区间）

    private func load() async {
        let repo = HealthRepository.shared
        await repo.checkAuthorizationStatus()
        guard repo.isAuthorized else { state = .unauthorized; return }

        let range = CalendarRangeBuilder.weekRange(around: Date())
        async let stepsData = repo.fetchStepsRange(from: range.start, to: range.end)
        async let sleepData = repo.fetchSleepRange(from: range.start, to: range.end)
        let (steps, sleep) = await (stepsData, sleepData)

        let avgSteps = Self.average(steps.map(\.value)).map { Int($0.rounded()) }
        let avgSleep = Self.average(sleep.map(\.value))

        var phrases: [String] = []
        if let s = avgSteps, s > 0 { phrases.append("\(s) 步") }
        if let h = avgSleep, h > 0 { phrases.append(String(format: "%.1f h", h)) }

        state = phrases.isEmpty
            ? .noData
            : .connected(summary: "本周 " + phrases.joined(separator: " · "))
    }

    private static func average(_ values: [Double]) -> Double? {
        let positive = values.filter { $0 > 0 }
        guard !positive.isEmpty else { return nil }
        return positive.reduce(0, +) / Double(positive.count)
    }
}
