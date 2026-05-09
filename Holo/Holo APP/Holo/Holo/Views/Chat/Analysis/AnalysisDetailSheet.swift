//
//  AnalysisDetailSheet.swift
//  Holo
//
//  分析结果详情 Sheet
//  AI 文本为主体，数据卡片作为可视化辅助嵌入
//

import SwiftUI

struct AnalysisDetailSheet: View {

    let message: ChatMessageViewData

    @State private var renderedBlocks: [AnalysisDetailBlockRenderItem] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // 标题区
                header

                // 内容区：AI 文本 + 嵌入卡片
                ForEach(renderedBlocks) { item in
                    switch item.block {
                    case .text(let text):
                        textBlock(text)
                    case .card(let slot):
                        cardBlock(slot)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
        .task {
            buildBlocks()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let context = message.analysisContext,
               let summary = AnalysisSummaryFormatter.format(from: context) {
                HStack(spacing: 8) {
                    Image(systemName: summary.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.holoPrimary)
                    Text(domainLabel(context.domain))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                }
                Text(summary.subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Text Block

    private func textBlock(_ text: String) -> some View {
        Text(MarkdownAttributedStringRenderer.parseSync(text) ?? AttributedString(text))
            .font(.holoBody)
            .foregroundColor(.holoTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Card Block

    @ViewBuilder
    private func cardBlock(_ slot: AnalysisCardSlot) -> some View {
        if let cardData = slotToCardData(slot) {
            switch cardData {
            case .analysisSummary(let data):
                AnalysisSummaryChatCard(data: data)
            case .analysisBreakdown(let data):
                AnalysisBreakdownChatCard(data: data)
            case .analysisTrend(let data):
                AnalysisTrendChatCard(data: data)
            case .analysisComparison(let data):
                AnalysisComparisonChatCard(data: data)
            case .analysisHighlights(let data):
                AnalysisHighlightsChatCard(data: data)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    private func buildBlocks() {
        let text = message.content
        let availableSlots = computeAvailableSlots()
        let blocks = AnalysisDetailBlockParser.parse(text: text, availableSlots: availableSlots)
        renderedBlocks = blocks.enumerated().map { index, block in
            AnalysisDetailBlockRenderItem(id: index, block: block)
        }
    }

    private func computeAvailableSlots() -> Set<AnalysisCardSlot> {
        let cards = message.analysisCards
        var slots = Set<AnalysisCardSlot>()

        for card in cards {
            switch card {
            case .analysisSummary: slots.insert(.summary)
            case .analysisBreakdown: slots.insert(.breakdown)
            case .analysisTrend: slots.insert(.trend)
            case .analysisComparison: slots.insert(.comparison)
            case .analysisHighlights: slots.insert(.highlights)
            default: break
            }
        }

        return slots
    }

    private func slotToCardData(_ slot: AnalysisCardSlot) -> ChatCardData? {
        for card in message.analysisCards {
            switch card {
            case .analysisSummary where slot == .summary,
                 .analysisBreakdown where slot == .breakdown,
                 .analysisTrend where slot == .trend,
                 .analysisComparison where slot == .comparison,
                 .analysisHighlights where slot == .highlights:
                return card
            default:
                continue
            }
        }
        return nil
    }

    private func domainLabel(_ domain: AnalysisDomain) -> String {
        switch domain {
        case .finance: return "账单分析"
        case .habit: return "习惯分析"
        case .task: return "任务分析"
        case .thought: return "想法分析"
        case .crossModule: return "综合分析"
        }
    }
}

/// ForEach 渲染包装
private struct AnalysisDetailBlockRenderItem: Identifiable {
    let id: Int
    let block: AnalysisDetailBlock
}
