//
//  HighlightNode.swift
//  Holo
//
//  高亮卡片 — 算法筛选的值得注意事件
//  偏右缩进，按正面/负面/成就分色
//

import SwiftUI

struct HighlightNode: View {
    let data: HighlightData

    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(textColor.opacity(0.12))
                    .frame(width: 34, height: 34)

                Image(systemName: data.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(textColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(data.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let subtitle = data.subtitle {
                    Text(subtitle)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Color Resolution

    private var textColor: Color {
        switch data.tone {
        case .positive: return .holoPrimary
        case .negative: return .holoError
        case .achievement: return .holoPrimary
        }
    }

    private var borderColor: Color {
        switch data.tone {
        case .positive: return Color.holoPrimary.opacity(0.2)
        case .negative: return Color.holoError.opacity(0.2)
        case .achievement: return Color.holoSuccess.opacity(0.2)
        }
    }

    private var backgroundColor: Color {
        switch data.tone {
        case .positive: return Color.holoPrimary.opacity(0.06)
        case .negative: return Color.holoError.opacity(0.06)
        case .achievement: return Color.holoSuccess.opacity(0.06)
        }
    }
}
