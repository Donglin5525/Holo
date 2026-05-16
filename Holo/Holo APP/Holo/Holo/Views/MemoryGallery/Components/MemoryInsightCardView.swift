//
//  MemoryInsightCardView.swift
//  Holo
//
//  单张洞察卡片视图
//  展示 title + body + evidence 列表
//

import SwiftUI

/// 单张 AI 洞察卡片
struct MemoryInsightCardView: View {

    let card: MemoryInsightCard
    /// anomaly 卡片的严重度，用于区分颜色。非 anomaly 卡片传 nil
    var anomalySeverity: AnomalySeverity?

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 类型图标 + 标题
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(cardColor.opacity(0.12))
                        .frame(width: 34, height: 34)

                    Image(systemName: cardIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(cardColor)
                }

                Text(card.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if !card.evidence.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextPlaceholder)
                        .padding(.top, 7)
                }
            }

            // 正文
            Text(card.body)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(isExpanded ? nil : 2)

            // 展开的 evidence
            if isExpanded {
                evidenceList
            }

            // 建议追问
            if let question = card.suggestedQuestion, !question.isEmpty {
                HStack(spacing: HoloSpacing.xs) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .foregroundColor(.holoPrimary)

                    Text(question)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                .padding(.top, HoloSpacing.xs)
            }
        }
        .padding(HoloSpacing.md)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .onTapGesture {
            guard !card.evidence.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Evidence List

    @ViewBuilder
    private var evidenceList: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            ForEach(card.evidence) { ev in
                HStack(spacing: HoloSpacing.xs) {
                    Circle()
                        .fill(Color.holoBorder)
                        .frame(width: 4, height: 4)

                    Text(ev.label)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, HoloSpacing.xs)
    }

    // MARK: - Card Style

    private var cardIcon: String {
        switch card.type {
        case .habit: return "figure.run"
        case .finance: return "yensign.circle"
        case .task: return "checkmark.circle"
        case .thought: return "bubble.left"
        case .milestone: return "flag.fill"
        case .crossDomain: return "arrow.triangle.2.circlepath"
        case .overview: return "chart.bar"
        case .anomaly:
            switch anomalySeverity {
            case .critical: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            default: return "info.circle.fill"
            }
        }
    }

    private var cardColor: Color {
        switch card.type {
        case .habit: return .holoSuccess
        case .finance: return .holoPrimary
        case .task: return .holoPrimary
        case .thought: return .holoPrimary
        case .milestone: return .holoPrimary
        case .crossDomain: return .holoPrimary
        case .overview: return .holoTextSecondary
        case .anomaly:
            switch anomalySeverity {
            case .critical: return .red
            case .warning: return .orange
            default: return .holoPrimary
            }
        }
    }

    private var cardBackgroundColor: Color {
        if card.type == .anomaly {
            return cardColor.opacity(0.07)
        }
        return Color.holoCardBackground
    }

    private var cardBorderColor: Color {
        card.type == .anomaly ? cardColor.opacity(0.28) : Color.holoBorder.opacity(0.45)
    }
}
