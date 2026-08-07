//
//  CardShareImageRenderer.swift
//  Holo
//
//  卡片分享：把聊天里的卡片渲染成带水印的图片用于分享
//

import SwiftUI
import UIKit

/// 卡片截图渲染器：把卡片视图渲染成 UIImage，右下角加 Holo 小水印
enum CardShareImageRenderer {

    /// 截图宽度（与聊天卡片宽度一致，保证视觉一致）
    private static let renderWidth: CGFloat = 360

    /// 把消息的卡片内容渲染成带水印的图片
    static func render(message: ChatMessageViewData) -> UIImage? {
        let cardContent = CardShareContentView(message: message)
        let watermarked = WatermarkedCardShareView(content: cardContent)

        var renderer = ImageRenderer(content: watermarked)
        renderer.scale = UIScreen.main.scale
        renderer.proposedSize.width = renderWidth

        guard let image = renderer.uiImage else { return nil }
        return image
    }
}

// MARK: - 截图用的纯展示卡片内容（无交互控件）

/// 根据 message 类型重建卡片视觉（只读，所有闭包为空，不含三个点/外层 Button）
/// 复用现有卡片组件，传入空闭包，保证视觉与聊天内一致。
private struct CardShareContentView: View {

    let message: ChatMessageViewData

    var body: some View {
        // 深度分析卡片：分享完整详情长图（不是聊天里的折叠入口卡片）
        if message.isQueryAnalysis, let result = message.agentResult {
            AgentDeepAnalysisShareContentView(result: result)
        }
        // 紧凑分析卡片
        else if message.isQueryAnalysis, message.analysisContext != nil {
            AnalysisCompactChatCard(message: message)
        }
        // 周期回放
        else if message.messageType == .periodReplay {
            PeriodReplayChatCard(message: message) { _ in }
        }
        // 批处理/单卡片
        else {
            shareCardList
        }
    }

    /// 分析卡片 + 领域操作卡片的通用列表
    @ViewBuilder
    private var shareCardList: some View {
        let analysisCards = message.analysisCards
        let execCards = ChatCardData.multiple(from: message.executionBatch)
        let singleCard: ChatCardData? = {
            guard execCards.isEmpty else { return nil }
            guard let intentStr = message.intent,
                  let intent = AIIntent(rawValue: intentStr),
                  !message.isStreaming else { return nil }
            return ChatCardData.from(intent: intent, data: message.extractedDataDictionary)
        }()
        let flexible = message.flexibleQueryCard

        VStack(alignment: .leading, spacing: 12) {
            if !analysisCards.isEmpty {
                ForEach(Array(analysisCards.enumerated()), id: \.offset) { _, card in
                    shareCardView(for: card)
                }
            }
            if let flexible {
                shareCardView(for: flexible)
            }
            if execCards.count > 1 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoSuccess)
                    Text("已为你处理 \(execCards.count) 件事")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                }
                ForEach(Array(execCards.enumerated()), id: \.offset) { _, card in
                    shareCardView(for: card)
                }
            } else if let card = execCards.first {
                shareCardView(for: card)
            } else if let singleCard {
                shareCardView(for: singleCard)
            }
        }
    }

    /// 单个领域卡片（只读版：不传确认/修改等闭包）
    @ViewBuilder
    private func shareCardView(for data: ChatCardData) -> some View {
        switch data {
        case .transaction(let txData):
            TransactionChatCard(data: txData, isDeleted: message.isEntityDeleted(for: .finance))
        case .task(let taskData):
            TaskChatCard(data: taskData, isDeleted: message.isEntityDeleted(for: .task))
        case .habitCheckIn(let habitData):
            HabitCheckInChatCard(data: habitData)
        case .mood(let moodData):
            MoodChatCard(data: moodData)
        case .weight(let weightData):
            WeightChatCard(data: weightData)
        case .analysisSummary(let summaryData):
            AnalysisSummaryChatCard(data: summaryData)
        case .analysisTrend(let trendData):
            AnalysisTrendChatCard(data: trendData)
        case .analysisBreakdown(let breakdownData):
            AnalysisBreakdownChatCard(data: breakdownData)
        case .analysisComparison(let comparisonData):
            AnalysisComparisonChatCard(data: comparisonData)
        case .analysisHighlights(let highlightsData):
            AnalysisHighlightsChatCard(data: highlightsData)
        case .flexibleQuery(let queryData):
            FlexibleQueryChatCard(data: queryData) { _ in } onViewAllTap: {}
        }
    }
}

// MARK: - 水印容器

/// 卡片内容 + 右下角 Holo 小水印
private struct WatermarkedCardShareView<Content: View>: View {

    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content

            // 右下角水印
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Holo")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color.holoBackground)
    }
}
