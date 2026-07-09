//
//  WeeklyObservationCard.swift
//  Holo
//
//  ChatView 顶部「本周观察」展示区块（方案 §4.5 / 决策 1A）
//  复用 HoloAI 卡片视觉语言（holoCardBackground + HoloRadius + HoloSpacing）；
//  未授权态作为正式版统一授权入口（决策 2A，复用 .aiSettings sheet，不受 #if DEBUG 限制）。
//

import SwiftUI

struct WeeklyObservationCard: View {

    /// 正在重新生成，卡片立即显示进度并防止重复请求
    let isRetrying: Bool
    /// 当前页面最近一次重试错误，优先于持久化的旧错误
    let retryErrorMessage: String?
    /// 点击「开启授权」→ 跳 AI 设置授权页（正式版可用，决策 2A）
    let onOpenConsent: () -> Void
    /// 点击「查看完整观察」→ 跳记忆长廊
    let onViewDetail: () -> Void
    /// 点击「重试」→ 重新生成本周观察（失败态）
    let onRetry: () -> Void
    /// 点击「×」→ 当天不再显示卡片
    let onClose: () -> Void

    /// 养成进度变化时刷新（@ObservedObject）
    @ObservedObject private var effectiveRecordDay = EffectiveRecordDayService.shared

    var body: some View {
        // body 内单次取数，避免多次 fetch
        let insight = Self.fetchWeeklyInsight()
        let consentGranted = HoloAIFeatureFlags.aiDataProcessingConsentGranted

        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header(insight: insight, consentGranted: consentGranted)
            content(insight: insight, consentGranted: consentGranted)
            action(insight: insight, consentGranted: consentGranted)
        }
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
        .onAppear { markReadIfNeeded(insight: insight, consentGranted: consentGranted) }
    }

    // MARK: - Display Decision

    private static let hiddenDateKey = "holo.weeklyObsCard.hiddenDate"

    /// 用户主动关闭卡片 → 当天不再展示（未读新观察仍优先弹出）
    static func hideForToday() {
        UserDefaults.standard.set(Date(), forKey: hiddenDateKey)
    }

    private static var hiddenToday: Bool {
        guard let d = UserDefaults.standard.object(forKey: hiddenDateKey) as? Date else { return false }
        return Calendar.current.isDateInToday(d)
    }

    /// ChatView 据此决定是否渲染本卡片
    static var shouldDisplay: Bool {
        if !HoloAIFeatureFlags.aiDataProcessingConsentGranted { return true }   // 未授权 → 引导
        // 未读新观察优先（即使当天关闭过也展示新内容）
        if let insight = fetchWeeklyInsight(),
           insight.readAt == nil,
           insight.insightStatus == .ready || insight.insightStatus == .stale {
            return true
        }
        if hiddenToday { return false }                                         // 当天已关闭 → 隐藏
        if fetchWeeklyInsight() != nil { return true }                          // 有观察记录 → 展示（供回看）
        return EffectiveRecordDayService.shared.currentResult?.eligibility != .fullReady
    }

    // MARK: - Header

    @ViewBuilder
    private func header(insight: MemoryInsight?, consentGranted: Bool) -> some View {
        let title = headerTitle(insight: insight, consentGranted: consentGranted)
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoPrimary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(width: 24, height: 24)
            }
        }
    }

    private func headerTitle(insight: MemoryInsight?, consentGranted: Bool) -> String {
        if !consentGranted { return "本周观察" }
        if let insight = insight,
           insight.insightStatus == .ready || insight.insightStatus == .stale {
            return insight.observationStageEnum == .light3d ? "初步观察" : "本周观察"
        }
        return "本周观察"
    }

    // MARK: - Content

    @ViewBuilder
    private func content(insight: MemoryInsight?, consentGranted: Bool) -> some View {
        if !consentGranted {
            Text("开启 AI 数据处理授权后，Holo 才能为你生成本周观察。")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        } else if let insight = insight,
                  insight.insightStatus == .ready || insight.insightStatus == .stale {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(insight.summary.isEmpty ? "Holo 已为你整理本周观察。" : insight.summary)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                // 主观察正文（第一条洞察卡片 body），让用户在 Chat 内直接看到核心结论
                if let mainCard = insight.parsedPayload?.cards.first,
                   !mainCard.body.isEmpty {
                    Text(mainCard.body)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if insight.observationStageEnum == .light3d {
                    Text("基于最近 3 个有效记录日的初步观察，持续记录到 7 天后会更完整。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
        } else if let insight = insight, insight.insightStatus == .failed {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("本周观察生成失败，点「重试」重新生成。")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                if let msg = retryErrorMessage ?? insight.errorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(2)
                }
            }
        } else if let result = effectiveRecordDay.currentResult {
            Text(nurturingMessage(result))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        } else {
            Text("Holo 正在认识你，开始记录后会逐渐发现你的生活模式。")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Action

    @ViewBuilder
    private func action(insight: MemoryInsight?, consentGranted: Bool) -> some View {
        if !consentGranted {
            primaryButton("开启授权", action: onOpenConsent)
        } else if let insight = insight, insight.insightStatus == .failed {
            if isRetrying {
                HStack(spacing: HoloSpacing.sm) {
                    ProgressView()
                        .tint(.holoPrimary)
                    Text("正在重新生成…")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在重新生成本周观察")
            } else {
                primaryButton("重试", action: onRetry)
            }
        } else if let insight = insight,
                  insight.insightStatus == .ready || insight.insightStatus == .stale {
            primaryButton("查看完整观察", action: onViewDetail)
        }
        // 养成期无数据：纯引导文案，无按钮
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Helpers

    /// 取最新 weekly 观察记录（不限本周，与首页胶囊共用同一条，避免范围不一致）
    private static func fetchWeeklyInsight() -> MemoryInsight? {
        MemoryInsightRepository().fetchLatestReadyInsight(periodType: .weekly)
    }

    private func nurturingMessage(_ result: EffectiveRecordDayResult) -> String {
        if result.recordDayCount == 0 {
            return "Holo 正在认识你，开始记录后会逐渐发现你的生活模式。"
        }
        return result.nurturingHint
    }

    /// 卡片展示即视为已读（回写 readAt，首页胶囊不再顶置同条观察，方案 §7.5）
    private func markReadIfNeeded(insight: MemoryInsight?, consentGranted: Bool) {
        guard consentGranted,
              let insight = insight,
              insight.readAt == nil,
              insight.insightStatus == .ready || insight.insightStatus == .stale else {
            return
        }
        try? MemoryInsightRepository().markRead(insight: insight)
    }
}
