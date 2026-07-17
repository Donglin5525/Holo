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

    @Environment(\.colorScheme) private var colorScheme

    let state: InsightGenerationState
    let selectedPeriod: MemoryInsightPeriodType
    let insight: MemoryInsight?
    let weeklyIsFallback: Bool
    let monthlyIsFallback: Bool
    @Binding var customStartDate: Date
    @Binding var customEndDate: Date
    let fallbackTitle: String
    let fallbackSummary: String
    let onPeriodChange: (MemoryInsightPeriodType) -> Void
    let onCustomRangeChange: (Date, Date) -> Void
    let onGenerate: () -> Void
    let insightRefreshRemaining: Int
    let insightRefreshTotal: Int
    let onRefresh: () -> Void
    let onContinueInChat: () -> Void
    let onInsightActionContinueInChat: (String) -> Void
    let onGoToAISettings: () -> Void

    @State private var isCardsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题区域
            headerSection

            if selectedPeriod == .custom {
                customDatePicker
            }

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
        Menu {
            periodMenuButton(weeklyIsFallback ? "上周" : "本周", period: .weekly)
            periodMenuButton(monthlyIsFallback ? "上月" : "本月", period: .monthly)
            periodMenuButton("本季度", period: .quarterly)
            periodMenuButton("自定义周期", period: .custom)
        } label: {
            HStack(spacing: 6) {
                Text(selectedPeriodTitle)
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, HoloSpacing.sm)
            .frame(height: 30)
            .background(periodPickerBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(periodPickerBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var periodPickerBackground: Color {
        Color.holoPrimary.opacity(colorScheme == .dark ? 0.16 : 0.1)
    }

    private var periodPickerBorder: Color {
        Color.holoPrimary.opacity(colorScheme == .dark ? 0.38 : 0.24)
    }

    private func periodMenuButton(_ title: String, period: MemoryInsightPeriodType) -> some View {
        Button {
            onPeriodChange(period)
        } label: {
            Label(title, systemImage: selectedPeriod == period ? "checkmark" : "calendar")
        }
    }

    private var selectedPeriodTitle: String {
        switch selectedPeriod {
        case .weekly:
            return weeklyIsFallback ? "上周" : "本周"
        case .monthly:
            return monthlyIsFallback ? "上月" : "本月"
        case .quarterly:
            return "本季度"
        case .custom:
            return customRangeTitle
        case .daily:
            return "今日"
        }
    }

    private var customRangeTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M.d"
        return "\(formatter.string(from: customStartDate))-\(formatter.string(from: customEndDate))"
    }

    private var customDatePicker: some View {
        VStack(spacing: HoloSpacing.sm) {
            customDateRow(title: "开始", selection: $customStartDate)
            customDateRow(title: "结束", selection: $customEndDate)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
        .onChange(of: customStartDate) { _, newValue in
            if newValue.startOfDay > customEndDate.startOfDay {
                customEndDate = newValue.startOfDay
            }
            onCustomRangeChange(customStartDate.startOfDay, customEndDate.startOfDay)
        }
        .onChange(of: customEndDate) { _, newValue in
            if newValue.startOfDay < customStartDate.startOfDay {
                customStartDate = newValue.startOfDay
            }
            onCustomRangeChange(customStartDate.startOfDay, customEndDate.startOfDay)
        }
    }

    private func customDateRow(title: String, selection: Binding<Date>) -> some View {
        HStack {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            DatePicker(
                title,
                selection: selection,
                in: ...Date().startOfDay,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(.holoPrimary)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text("AI 回放")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer(minLength: HoloSpacing.sm)

                periodPicker
            }

            Text(headerTitle)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: HoloSpacing.sm) {
                if state == .stale {
                    Text("有新记录")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Color.holoPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }

                if let insight = insight, state == .ready || state == .stale {
                    Text(insight.formattedGeneratedAt)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
        }
    }

    private var headerTitle: String {
        let periodLabel = selectedPeriodInsightLabel
        switch state {
        case .notConfigured:
            return "AI 回放"
        case .needConsent:
            return "AI 回放"
        case .idle:
            return "\(periodLabel) AI 回放"
        case .generating:
            return "正在理解\(periodLabel)"
        case .ready:
            return insight?.title ?? "AI 回放"
        case .stale:
            return insight?.title ?? "AI 回放"
        case .failed:
            return "生成失败"
        }
    }

    private var selectedPeriodInsightLabel: String {
        switch selectedPeriod {
        case .weekly:
            return weeklyIsFallback ? "上周" : "本周"
        case .monthly:
            return monthlyIsFallback ? "上月" : "本月"
        case .quarterly:
            return "本季度"
        case .custom:
            return "自定义周期"
        case .daily:
            return "今日"
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        switch state {
        case .notConfigured:
            Text("AI 服务暂时不可用，请稍后重试")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

        case .needConsent:
            Text("开启 AI 数据处理授权后，Holo 才能为你生成本周观察")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

        case .idle:
            missingReplayPlaceholder

        case .generating:
            HStack(spacing: HoloSpacing.sm) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
                Text("AI 正在阅读你的记账、习惯、任务和观点")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }

        case .ready, .stale:
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(insight?.summary ?? "")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .textSelection(.enabled)
                // light3d 承诺文案：强调是初步观察，不冒充完整周报（方案 §2.3 合规）
                if insight?.observationStageEnum == .light3d {
                    Text("基于最近 3 个有效记录日的初步观察，持续记录到 7 天后会更完整。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }

        case .failed(let message):
            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoError)
        }
    }

    private var missingReplayPlaceholder: some View {
        HStack(alignment: .center, spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(missingReplayIconBackground)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .stroke(missingReplayIconBorder, lineWidth: 1)
                    )

                Image(systemName: "calendar.badge.sparkles")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("还没有生成\(selectedPeriodInsightLabel)回放")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("生成后这里会展示该时间范围内的洞察与关键事件")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(missingReplayBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(missingReplayBorder, lineWidth: 1)
        )
    }

    private var missingReplayBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.holoGlassBackground
    }

    private var missingReplayBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.holoBorder.opacity(0.45)
    }

    private var missingReplayIconBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.holoPrimary.opacity(0.1)
    }

    private var missingReplayIconBorder: Color {
        Color.holoPrimary.opacity(colorScheme == .dark ? 0.55 : 0.16)
    }

    // MARK: - Insight Cards

    private func insightCardsSection(_ payload: MemoryInsightPayload) -> some View {
        let actionMap = InsightActionCandidateBuilder.buildCandidateMap(
            cards: payload.cards,
            context: nil
        )

        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ForEach(displayedCards(payload)) { card in
                MemoryInsightCardView(
                    card: card,
                    anomalySeverity: card.anomalySeverity,
                    insightId: insight?.id,
                    actionCandidate: actionMap[card.id],
                    onContinueInChat: onInsightActionContinueInChat
                )
            }

            // 展开更多卡片
            if payload.cards.count > defaultDisplayCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCardsExpanded.toggle()
                    }
                } label: {
                    Text(isCardsExpanded ? "收起" : "查看更多 (\(payload.cards.count - defaultDisplayCount))")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoPrimary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private let defaultDisplayCount = 5

    private func displayedCards(_ payload: MemoryInsightPayload) -> [MemoryInsightCard] {
        let limit = isCardsExpanded ? max(payload.cards.count, 7) : defaultDisplayCount
        return Array(payload.cards.prefix(limit))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            let periodLabel: String = {
                switch selectedPeriod {
                case .weekly: return weeklyIsFallback ? "上周" : "本周"
                case .monthly: return monthlyIsFallback ? "上月" : "本月"
                case .quarterly: return "本季度"
                case .custom: return "自定义周期"
                case .daily: return "今日"
                }
            }()
            switch state {
            case .notConfigured:
                Button(action: onGenerate) {
                    actionButtonLabel("稍后重试", isPrimary: true)
                }

            case .needConsent:
                // 跳转 AI 设置授权入口（方案 §4.1.3 / Phase 6）
                Button(action: onGoToAISettings) {
                    actionButtonLabel("开启授权", isPrimary: true)
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
                .disabled(quotaExhausted)

            case .stale:
                Button(action: onRefresh) {
                    actionButtonLabel("刷新洞察", isPrimary: true)
                }
                .disabled(quotaExhausted)
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

    /// AI 洞察刷新配额是否耗尽（与星图「更新」共享同一配额池）。
    private var quotaExhausted: Bool {
        insightRefreshRemaining <= 0
    }
}

// MARK: - Preview

#Preview("Not Configured") {
    MemoryInsightHeroCard(
        state: .notConfigured,
        selectedPeriod: .weekly,
        insight: nil,
        weeklyIsFallback: false,
        monthlyIsFallback: false,
        customStartDate: .constant(Date().addingDays(-6)),
        customEndDate: .constant(Date()),
        fallbackTitle: "标题",
        fallbackSummary: "摘要",
        onPeriodChange: { _ in },
        onCustomRangeChange: { _, _ in },
        onGenerate: {},
        insightRefreshRemaining: MemoryInsightRefreshQuota.maxPerDay,
        insightRefreshTotal: MemoryInsightRefreshQuota.maxPerDay,
        onRefresh: {},
        onContinueInChat: {},
        onInsightActionContinueInChat: { _ in },
        onGoToAISettings: {}
    )
    .padding()
}

#Preview("Ready") {
    MemoryInsightHeroCard(
        state: .ready,
        selectedPeriod: .weekly,
        insight: nil,
        weeklyIsFallback: false,
        monthlyIsFallback: false,
        customStartDate: .constant(Date().addingDays(-6)),
        customEndDate: .constant(Date()),
        fallbackTitle: "",
        fallbackSummary: "",
        onPeriodChange: { _ in },
        onCustomRangeChange: { _, _ in },
        onGenerate: {},
        insightRefreshRemaining: MemoryInsightRefreshQuota.maxPerDay,
        insightRefreshTotal: MemoryInsightRefreshQuota.maxPerDay,
        onRefresh: {},
        onContinueInChat: {},
        onInsightActionContinueInChat: { _ in },
        onGoToAISettings: {}
    )
    .padding()
}
