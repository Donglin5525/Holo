//
//  MonthlySummaryCard.swift
//  Holo
//
//  月度收支概览卡片 — 左右两列布局（本月数据 | 今日数据）
//  支持全宽（单卡片）和紧凑（双卡片并排）两种模式
//

import SwiftUI

struct MonthlySummaryCard: View {
    let title: String
    let amount: Decimal
    let previousAmount: Decimal?
    let iconName: String
    let iconColor: Color
    let isCompact: Bool

    /// 今日金额（nil 时不显示右列）
    var todayAmount: Decimal? = nil

    // MARK: 数字逐位落定（2026-11-23 审美七项 P3）

    /// 本月合计的衬线主角数字字号（令牌口径：holoHeroNumber 只用于 ≥28pt）
    private static let heroNumberSize: CGFloat = 28
    /// 落定标记的有效窗口（手动记账后金额刷新通常在 1 秒内到达）
    private static let settleWindow: Duration = .seconds(5)
    @State private var settleWindowTask: Task<Void, Never>?

    /// 渲染用金额：只有手动记账后的那一次变化走落定动画，切月/同步直接换值
    @State private var displayedAmount: Decimal?
    @State private var displayedTodayAmount: Decimal?
    /// 收到手动记账通知后为 true，被随后那次金额变化消耗（月份/今日各一份，避免互相抢先清掉）
    @State private var settlesAmountChange = false
    @State private var settlesTodayChange = false
    /// 落定被记账弹层挡住：金额已在弹层下更新、等回到账本可见再播（同 HoloRecordArrival 的等待口径）
    @State private var deferredAmountSettle = false
    @State private var deferredTodaySettle = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.holoMotionSurfaceIsActive) private var surfaceActive
    @AppStorage(HoloMotionRollout.recordKey) private var recordMotionEnabled = true

    /// 是否允许播放落定（记账反馈开关 + 减弱动态效果）
    private var allowsSettle: Bool {
        recordMotionEnabled && !reduceMotion
    }

    private var effectiveAmount: Decimal {
        displayedAmount ?? amount
    }

    private var effectiveTodayAmount: Decimal? {
        displayedTodayAmount ?? todayAmount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: 标题行 — 左侧图标+标题 | 右侧"今日"
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundColor(iconColor)
                    Text(title)
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }

                Spacer(minLength: 0)

                if todayAmount != nil {
                    Text("今日")
                        .holoText(.metadata)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }

            // Row 2: 金额行 — 本月金额(左，衬线主角数字) | 今日金额(右，次级小字)
            HStack(alignment: .firstTextBaseline) {
                Text(formatAmount(effectiveAmount))
                    .font(.holoHeroNumber(size: Self.heroNumberSize))
                    .monospacedDigit()
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText(value: Double(truncating: effectiveAmount as NSDecimalNumber)))

                Spacer(minLength: 0)

                if let today = effectiveTodayAmount {
                    Text(formatAmount(today))
                        .holoText(.supporting)
                        .monospacedDigit()
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                        .contentTransition(.numericText(value: Double(truncating: today as NSDecimalNumber)))
                }
            }

            // Row 3: 环比（始终占位，保持双卡片高度一致）
            Group {
                if let prev = previousAmount, prev > 0 {
                    comparisonView(current: amount, previous: prev)
                } else {
                    Text(" ")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(20)
        // 月度卡片位于账本页的白色大面板内，必须是带底色的嵌套卡；
        // holoSurface 体系(independent/floating 均白底)在白面板上会隐形
        .holoNestedCard()
        .onAppear {
            displayedAmount = amount
            displayedTodayAmount = todayAmount
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoManualFinanceRecordSaved)) { _ in
            // 只有手动记账成功才发这条通知；切月/同步刷新不会发
            guard allowsSettle else { return }
            settlesAmountChange = true
            settlesTodayChange = true
            // 标记只在这段窗口内有效：记的是别的月份等情况金额不会变，到期作废，
            // 免得之后再切月时误播一次落定
            settleWindowTask?.cancel()
            settleWindowTask = Task { @MainActor in
                try? await Task.sleep(for: Self.settleWindow)
                settlesAmountChange = false
                settlesTodayChange = false
            }
        }
        .onChange(of: amount) { _, newValue in
            let settles = settlesAmountChange
            settlesAmountChange = false
            if settles, surfaceActive {
                withAnimation(HoloAnimation.recordSettle) { displayedAmount = newValue }
            } else if settles {
                // 记账弹层还盖着：保持旧值，回到账本可见后再落定
                deferredAmountSettle = true
            } else {
                deferredAmountSettle = false
                displayedAmount = newValue
            }
        }
        .onChange(of: todayAmount) { _, newValue in
            let settles = settlesTodayChange
            settlesTodayChange = false
            if settles, surfaceActive {
                withAnimation(HoloAnimation.recordSettle) { displayedTodayAmount = newValue }
            } else if settles {
                deferredTodaySettle = true
            } else {
                deferredTodaySettle = false
                displayedTodayAmount = newValue
            }
        }
        .onChange(of: surfaceActive) { _, active in
            guard active, deferredAmountSettle || deferredTodaySettle else { return }
            // 等弹层真正退出后再播，避免数字在遮罩下滑过（同 HoloRecordArrival 的等待口径）
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(HoloScreenTransitionMetrics.duration)) } catch { return }
                playDeferredSettles()
            }
        }
    }

    /// 弹层退出后补播被挡住的落定
    private func playDeferredSettles() {
        if deferredAmountSettle {
            deferredAmountSettle = false
            withAnimation(HoloAnimation.recordSettle) { displayedAmount = amount }
        }
        if deferredTodaySettle {
            deferredTodaySettle = false
            withAnimation(HoloAnimation.recordSettle) { displayedTodayAmount = todayAmount }
        }
    }

    // MARK: - Helper

    private func formatAmount(_ value: Decimal) -> String {
        if isCompact {
            return NumberFormatter.compactCurrency(value)
        }
        return NumberFormatter.currency.string(from: value as NSDecimalNumber) ?? "¥0.00"
    }

    // MARK: - 环比视图

    @ViewBuilder
    private func comparisonView(current: Decimal, previous: Decimal) -> some View {
        let change = current - previous
        let percentage = Double(truncating: (abs(change) / previous * 100) as NSDecimalNumber)
        let isIncrease = change > 0
        let isNeutral = change == 0
        // 方向写进数字本体(+/-)，不靠颜色单独承担语义——月初零账打出无方向的「100.0%」
        // 会被读成好消息（11-05 挑刺 P1：数字诚实口径）
        let signedPercentage = isIncrease ? percentage : -percentage

        Group {
            if isNeutral {
                Text("与上月同期持平")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text(String(format: String(localized: "较上月同期 %+.1f%%"), signedPercentage))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundColor(isIncrease ? .holoError : (isNeutral ? .holoToolTextSecondary : .holoSuccess))
    }
}
