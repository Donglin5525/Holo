//
//  MemoryInsightHeroCard.swift
//  Holo
//
//  AI 洞察 Hero 卡片
//  支持 6 种状态：notConfigured / idle / generating / ready / stale / failed
//

import SwiftUI

/// AI 洞察 Hero 卡片
struct MemoryInsightHeroCard: View {

    let state: InsightGenerationState
    let selectedPeriod: MemoryInsightPeriodType
    let insight: MemoryInsight?
    let fallbackTitle: String
    let fallbackSummary: String
    let onPeriodChange: (MemoryInsightPeriodType) -> Void
    let onGenerate: () -> Void
    let onRefresh: () -> Void
    let onContinueInChat: () -> Void
    let onGoToAISettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 周/月切换器
            periodPicker

            // 标题区域
            headerSection

            // 摘要区域
            summarySection

            // 洞察卡（仅在 ready/stale 时展示）
            if (state == .ready || state == .stale), let payload = insight?.parsedPayload {
                insightCardsSection(payload)
            }

            // 操作按钮
            actionSection
        }
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Period Picker

    @ViewBuilder
    private var periodPicker: some View {
        HStack(spacing: 0) {
            periodTab("本周", period: .weekly)
            periodTab("本月", period: .monthly)
        }
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    private func periodTab(_ title: String, period: MemoryInsightPeriodType) -> some View {
        Button {
            onPeriodChange(period)
        } label: {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(selectedPeriod == period ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm / 2)
                        .fill(selectedPeriod == period ? Color.holoPrimary : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)

            Text(headerTitle)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // stale 标记
            if state == .stale {
                Text("有新记录")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoInfo)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 2)
                    .background(Color.holoInfo.opacity(0.1))
                    .clipShape(Capsule())
            }

            // 生成时间
            if let insight = insight, state == .ready || state == .stale {
                Text(insight.formattedGeneratedAt)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
    }

    private var headerTitle: String {
        let periodLabel = selectedPeriod == .weekly ? "周" : "月"
        switch state {
        case .notConfigured:
            return "AI 回放"
        case .idle:
            return "本\(periodLabel) AI 回放"
        case .generating:
            return "正在理解这一\(periodLabel)"
        case .ready:
            return insight?.title ?? "AI 回放"
        case .stale:
            return insight?.title ?? "AI 回放"
        case .failed:
            return "生成失败"
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        switch state {
        case .notConfigured:
            Text("配置 AI 后可以生成个性化的周/月回放")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

        case .idle:
            let periodLabel = selectedPeriod == .weekly ? "周" : "月"
            Text(fallbackSummary.isEmpty ? "本\(periodLabel)已有记录，可以让 AI 帮你整理成回放" : fallbackSummary)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

        case .generating:
            HStack(spacing: HoloSpacing.sm) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
                Text("AI 正在阅读你的记账、习惯、任务和观点")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }

        case .ready, .stale:
            Text(insight?.summary ?? "")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

        case .failed(let message):
            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoError)
        }
    }

    // MARK: - Insight Cards

    private func insightCardsSection(_ payload: MemoryInsightPayload) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ForEach(payload.cards.prefix(5)) { card in
                MemoryInsightCardView(card: card)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            let periodLabel = selectedPeriod == .weekly ? "本周" : "本月"
            switch state {
            case .notConfigured:
                Button(action: onGoToAISettings) {
                    actionButtonLabel("去配置 AI", isPrimary: true)
                }

            case .idle:
                Button(action: onGenerate) {
                    actionButtonLabel("生成\(periodLabel)回放", isPrimary: true)
                }

            case .generating:
                actionButtonLabel("生成中...", isPrimary: false)
                    .disabled(true)

            case .ready:
                Button(action: onContinueInChat) {
                    actionButtonLabel("继续问 AI", isPrimary: true)
                }
                Button(action: onRefresh) {
                    actionButtonLabel("重新生成", isPrimary: false)
                }

            case .stale:
                Button(action: onRefresh) {
                    actionButtonLabel("刷新洞察", isPrimary: true)
                }
                Button(action: onContinueInChat) {
                    actionButtonLabel("继续问 AI", isPrimary: false)
                }

            case .failed:
                Button(action: onGenerate) {
                    actionButtonLabel("重试", isPrimary: true)
                }
            }
        }
    }

    private func actionButtonLabel(_ text: String, isPrimary: Bool) -> some View {
        Text(text)
            .font(.holoCaption)
            .foregroundColor(isPrimary ? .white : .holoPrimary)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.xs)
            .background(
                Capsule()
                    .fill(isPrimary ? Color.holoPrimary : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(Color.holoPrimary, lineWidth: isPrimary ? 0 : 1)
            )
    }
}

// MARK: - Preview

#Preview("Not Configured") {
    MemoryInsightHeroCard(
        state: .notConfigured,
        selectedPeriod: .weekly,
        insight: nil,
        fallbackTitle: "标题",
        fallbackSummary: "摘要",
        onPeriodChange: { _ in },
        onGenerate: {},
        onRefresh: {},
        onContinueInChat: {},
        onGoToAISettings: {}
    )
    .padding()
}

#Preview("Ready") {
    MemoryInsightHeroCard(
        state: .ready,
        selectedPeriod: .weekly,
        insight: nil,
        fallbackTitle: "",
        fallbackSummary: "",
        onPeriodChange: { _ in },
        onGenerate: {},
        onRefresh: {},
        onContinueInChat: {},
        onGoToAISettings: {}
    )
    .padding()
}
