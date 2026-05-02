//
//  KanbanHealthSection.swift
//  Holo
//
//  今日看板 — 健康数据卡片（睡眠/步数/站立）
//

import SwiftUI

struct KanbanHealthSection: View {

    @ObservedObject var healthRepo: HealthRepository

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 12) {
                healthRings
                sleepDetail
            }
            .padding(16)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Label("健康数据", systemImage: "heart.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var healthRings: some View {
        HStack(spacing: 8) {
            healthRingItem(
                icon: "🛏️",
                value: String(format: "%.1f", healthRepo.todaySleep),
                unit: "h",
                goal: "目标 8h",
                progress: healthRepo.todaySleep / 8.0,
                color: .holoPurple
            )
            healthRingItem(
                icon: "🚶",
                value: formatSteps(healthRepo.todaySteps),
                unit: "步",
                goal: "目标 10,000",
                progress: healthRepo.todaySteps / 10000.0,
                color: .holoSuccess
            )
            healthRingItem(
                icon: "🧍",
                value: "\(Int(healthRepo.todayStandHours))",
                unit: "h",
                goal: "目标 12h",
                progress: healthRepo.todayStandHours / 12.0,
                color: .holoInfo
            )
        }
    }

    private func healthRingItem(
        icon: String,
        value: String,
        unit: String,
        goal: String,
        progress: Double,
        color: Color
    ) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 5)
                    .frame(width: 48, height: 48)

                Circle()
                    .trim(from: 0, to: min(progress, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))

                Text(icon)
                    .font(.system(size: 16))
            }

            (Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
                + Text(" \(unit)").font(.system(size: 10)).foregroundColor(.holoTextSecondary))
                .foregroundColor(.holoTextPrimary)

            Text(goal)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var sleepDetail: some View {
        HStack(spacing: 10) {
            Text("🌙")
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 2) {
                Text("昨晚睡眠 \(String(format: "%.1f", healthRepo.todaySleep)) 小时")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Text("健康数据由 Apple Health 提供")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Text(sleepQualityLabel)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(sleepQualityColor.opacity(0.15))
                .foregroundColor(sleepQualityColor)
                .clipShape(Capsule())
        }
        .padding(.top, 10)
    }

    // MARK: - Helpers

    private var sleepQualityLabel: String {
        let hours = healthRepo.todaySleep
        if hours >= 7 { return "良好" }
        if hours >= 6 { return "一般" }
        return "不足"
    }

    private var sleepQualityColor: Color {
        let hours = healthRepo.todaySleep
        if hours >= 7 { return .holoSuccess }
        if hours >= 6 { return Color.orange }
        return .holoError
    }

    private func formatSteps(_ steps: Double) -> String {
        let count = Int(steps)
        if count >= 10000 {
            return String(format: "%.1fk", steps / 1000.0)
        }
        return "\(count)"
    }
}
