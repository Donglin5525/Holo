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
            VStack(alignment: .leading, spacing: 20) {
                header

                if let readableModel {
                    readableIntro(readableModel)
                }

                ForEach(renderedBlocks) { item in
                    switch item.block {
                    case .text(let text):
                        if item.id != firstTextBlockId {
                            textBlock(text)
                        }
                    case .card(let slot):
                        cardBlock(slot)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 34)
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
        .task {
            buildBlocks()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let context = message.analysisContext,
               let summary = AnalysisSummaryFormatter.format(from: context) {
                HStack(spacing: 12) {
                    Image(systemName: summary.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 38, height: 38)
                        .background(Color.holoPrimary.opacity(0.12))
                        .clipShape(Circle())
                    Text(domainLabel(context.domain))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                }
                Text(summary.subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    // MARK: - Readable Intro

    @ViewBuilder
    private func readableIntro(_ model: AnalysisReadableModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text("核心结论")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .tracking(0.6)

                Text(model.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.holoPrimary.opacity(0.10), Color.holoCardBackground],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.holoPrimary.opacity(0.13), lineWidth: 1)
            )

            if !model.facts.isEmpty {
                HoloAISectionLabel(text: "事实")

                VStack(spacing: 12) {
                    ForEach(model.facts) { fact in
                        HoloAIFactItem(kicker: fact.kicker, bodyText: fact.body)
                    }
                }
            }

            if !model.remainingText.isEmpty {
                textBlock(model.remainingText)
            }
        }
    }

    // MARK: - Text Block

    private func textBlock(_ text: String) -> some View {
        Text(MarkdownAttributedStringRenderer.parseSync(text) ?? AttributedString(text))
            .font(.system(size: 16, weight: .regular))
            .foregroundColor(.holoTextPrimary)
            .lineSpacing(5)
            .textSelection(.enabled)
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

    private var firstTextBlockId: Int? {
        renderedBlocks.first { item in
            if case .text = item.block { return true }
            return false
        }?.id
    }

    private var readableModel: AnalysisReadableModel? {
        guard let item = renderedBlocks.first(where: { item in
            if case .text = item.block { return true }
            return false
        }),
        case .text(let text) = item.block else {
            return nil
        }
        return AnalysisReadableTextParser.parse(
            text: text,
            fallbackHeadline: fallbackHeadline
        )
    }

    private var fallbackHeadline: String {
        guard let context = message.analysisContext,
              let summary = AnalysisSummaryFormatter.format(from: context) else {
            return "这里有几条值得关注的变化。"
        }

        switch context.domain {
        case .finance:
            return "最近 30 天支出有明显抬高，主要压力集中在居住、购物和餐饮。"
        case .habit:
            return "这段时间的习惯表现可以从完成率、活跃习惯和连续记录里看。"
        case .task:
            return "任务进展可以先看完成率，再看逾期和未完成事项。"
        case .thought:
            return "想法记录已经整理成几个可继续回看的主题。"
        case .health:
            return "健康数据里有几项值得优先关注的变化。"
        case .goal:
            return "目标进展已经整理出当前状态和潜在风险。"
        case .crossModule:
            return "这次综合分析提炼了几个跨模块的变化和提醒。"
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
        case .health: return "健康分析"
        case .goal: return "目标分析"
        }
    }
}

/// ForEach 渲染包装
private struct AnalysisDetailBlockRenderItem: Identifiable {
    let id: Int
    let block: AnalysisDetailBlock
}
