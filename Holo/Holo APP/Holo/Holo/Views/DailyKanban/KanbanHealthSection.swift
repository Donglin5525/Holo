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
                if healthRepo.dataSourceState == .notRequested {
                    connectHealthCard
                }
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
        let snapshot = healthRepo.dashboardSnapshot
        return HStack(spacing: 8) {
            healthRingItem(
                icon: "🛏️",
                snapshot: snapshot.sleep,
                color: .holoPurple
            )
            healthRingItem(
                icon: "🚶",
                snapshot: snapshot.steps,
                color: .holoSuccess
            )
            healthRingItem(
                icon: snapshot.standOrActivity.type == .activeMinutes ? "🏃" : "🧍",
                snapshot: snapshot.standOrActivity,
                color: .holoInfo
            )
        }
    }

    private func healthRingItem(
        icon: String,
        snapshot: HealthMetricSnapshot,
        color: Color
    ) -> some View {
        let availability = effectiveAvailability(for: snapshot)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 5)
                    .frame(width: 48, height: 48)

                Circle()
                    .trim(from: 0, to: availability == .available ? snapshot.progress : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))

                Text(icon)
                    .font(.system(size: 16))
            }

            (Text(availability == .available ? snapshot.type.formatValue(snapshot.value) : "--")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                + Text(" \(snapshot.type.unit)").font(.system(size: 10)).foregroundColor(.holoTextSecondary))
                .foregroundColor(.holoTextPrimary)

            Text(availabilityText(availability, fallback: snapshot.targetText))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var connectHealthCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("连接 Apple Health")
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                Text("授权后只读同步步数、睡眠和活动数据")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Button("去授权") {
                healthRepo.requestAuthorization()
            }
            .font(.holoLabel)
            .fontWeight(.semibold)
            .foregroundColor(.holoPrimary)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var sleepDetail: some View {
        let availability = effectiveAvailability(for: healthRepo.dashboardSnapshot.sleep)
        return HStack(spacing: 10) {
            Text("🌙")
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    availability == .available
                        ? "昨晚睡眠 \(String(format: "%.1f", healthRepo.todaySleep)) 小时"
                        : sleepUnavailableTitle(availability)
                )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Text("健康数据由 Apple Health 提供")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            if availability == .available {
                Text(sleepQualityLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(sleepQualityColor.opacity(0.15))
                    .foregroundColor(sleepQualityColor)
                    .clipShape(Capsule())
            }
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

    private func effectiveAvailability(for snapshot: HealthMetricSnapshot) -> HealthMetricAvailability {
        switch healthRepo.dataSourceState {
        case .notRequested, .denied:
            return .unauthorized
        case .unavailable:
            return .unsupported
        case .connected, .partiallyConnected:
            return snapshot.availability
        }
    }

    private func availabilityText(_ availability: HealthMetricAvailability, fallback: String) -> String {
        switch availability {
        case .available:
            return fallback
        case .unauthorized:
            return "未授权"
        case .noData:
            return "暂无数据"
        case .unsupported:
            return "暂不支持"
        }
    }

    private func sleepUnavailableTitle(_ availability: HealthMetricAvailability) -> String {
        switch availability {
        case .available:
            return ""
        case .unauthorized:
            return "尚未授权睡眠数据"
        case .noData:
            return "昨晚暂无睡眠数据"
        case .unsupported:
            return "当前设备不支持睡眠数据"
        }
    }
}
