//
//  DailySenseStatusCard.swift
//  Holo
//
//  每日状态展示卡片
//  放在记忆长廊顶部，显示 stable/atRisk/recovering
//

import SwiftUI

struct DailySenseStatusCard: View {

    let snapshot: DailySenseSnapshot

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            // 状态图标
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.12))
                    .frame(width: 40, height: 40)

                Image(systemName: stateIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(stateColor)
            }

            // 状态文本
            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle)
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                if !snapshot.reasons.isEmpty {
                    Text(snapshot.reasons.joined(separator: " · "))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 置信度指示
            Circle()
                .fill(stateColor.opacity(0.6))
                .frame(width: 8, height: 8)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(stateColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Style

    private var stateColor: Color {
        switch snapshot.state {
        case .stable: return .holoSuccess
        case .atRisk: return .orange
        case .recovering: return .holoPrimary
        }
    }

    private var stateIcon: String {
        switch snapshot.state {
        case .stable: return "checkmark.circle.fill"
        case .atRisk: return "exclamationmark.triangle.fill"
        case .recovering: return "arrow.up.circle.fill"
        }
    }

    private var stateTitle: String {
        switch snapshot.state {
        case .stable: return "状态稳定"
        case .atRisk: return "需要注意"
        case .recovering: return "正在恢复"
        }
    }
}
