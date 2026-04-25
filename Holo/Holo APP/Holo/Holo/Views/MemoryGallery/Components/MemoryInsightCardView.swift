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

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 类型图标 + 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: cardIcon)
                    .font(.system(size: 14))
                    .foregroundColor(cardColor)

                Text(card.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)

                Spacer()

                if !card.evidence.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextPlaceholder)
                    }
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
                        .foregroundColor(.holoInfo)

                    Text(question)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                .padding(.top, HoloSpacing.xs)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
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
        }
    }

    private var cardColor: Color {
        switch card.type {
        case .habit: return .holoSuccess
        case .finance: return .holoPrimary
        case .task: return .holoInfo
        case .thought: return .holoInfo
        case .milestone: return .holoError
        case .crossDomain: return .holoPrimary
        case .overview: return .holoTextSecondary
        }
    }
}
