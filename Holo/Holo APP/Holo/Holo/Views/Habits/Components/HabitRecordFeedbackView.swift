//
//  HabitRecordFeedbackView.swift
//  Holo
//
//  页面内撤销/错误反馈条（2026-10 重构，方案 §11.3）：
//  safeAreaInset 挂在底部导航之上，不使用全局 overlay window toast。
//  超限警告形态（2026-10-07）：坏习惯超上限时红色感叹号 + 警告文案 +
//  warning 触觉（恢复旧磁贴版超限提示，形态按东林拍板并入本反馈条）。
//  警告美化（2026-10-07）：红圆徽章 + 标题/副标题两行层级（逗号拆分，只拆显示
//  不动词条）+ 淡红胶囊底 + 浅红撤销按钮（与页面打卡浅蓝胶囊同语言）。
//
//  底部倒计时条（2026-10-07 东林定稿「从右至左丝滑的走完」）：撤销窗口 7 秒从满
//  走到空，走完与收条同刻衔接；中途试做的「今日记录比例」进度条被东林真机验收否决
//  （涨到比例停住≠走完），已废弃。满帧率驱动（.animation 不节流，上一版 20fps 节流
//  =真机掉帧感直接原因）。
//  ⚠️ 实现红线：TimelineView 纯时钟驱动（画面=时间的函数），禁用 withAnimation/
//  mask+scaleEffect 组合——后者在真机 iOS 26 上动画静默失效（东林两轮「条不动」
//  事故根因，模拟器上正常=零证明力），任何动画需求一律改走时间插值。
//

import SwiftUI

struct HabitRecordFeedbackView: View {

    let hint: HabitModuleViewModel.UndoHint
    var onUndo: () -> Void
    var onExpire: () -> Void

    private let undoWindow: TimeInterval = 7

    private var isWarning: Bool { hint.style == .overLimit }

    private var progressColor: Color { isWarning ? .holoError : .holoPrimary }

    /// 警告文案按逗号拆成标题/副标题（如「已超当日限额，请注意控制」）；
    /// 无逗号或拆出空段时整句作标题，两行排版退化为单行。
    private var warningTextParts: (title: String, subtitle: String?) {
        for separator in ["，", ", "] {
            guard let range = hint.text.range(of: separator) else { continue }
            let title = String(hint.text[..<range.lowerBound])
            let subtitle = String(hint.text[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !subtitle.isEmpty else { continue }
            return (title, subtitle)
        }
        return (hint.text, nil)
    }

    var body: some View {
        HStack(spacing: 12) {
            if isWarning {
                ZStack {
                    Circle().fill(Color.holoError)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.holoPrimary)
                    .accessibilityHidden(true)
            }

            if isWarning, let subtitle = warningTextParts.subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(warningTextParts.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoError)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
            } else {
                Text(hint.text)
                    .holoText(.body)
                    .foregroundColor(isWarning ? .holoError : .holoToolText)
            }

            Spacer()

            Button {
                onUndo()
            } label: {
                Text(String(localized: "撤销"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(progressColor)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(
                        Capsule()
                            .fill(progressColor.opacity(0.10))
                    )
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.feedback.undo")
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.holoToolSurface)
                .overlay {
                    if isWarning {
                        Capsule().fill(Color.holoError.opacity(0.08))
                    }
                }
                .shadow(color: HoloShadow.card, radius: 12, x: 0, y: 4)
        )
        .overlay {
            // 撤销窗口倒计时条：从满开始 7 秒右→左匀速走完，走完与收条同刻衔接（2026-10-07 东林定稿
            // 「从右至左丝滑走完」，替换中途试做的今日进度条——涨到比例停住不符合预期）。
            // ⚠️ TimelineView 纯时钟驱动（画面=f(弹出了几秒)），禁用 withAnimation/mask+scaleEffect
            // 组合（真机 iOS 26 静默失效、模拟器正常=零证明力）；.animation 不节流，跟随系统刷新率。
            // clipShape 按背景胶囊同形裁剪（原版贴底全宽条两端溢出圆弧的缺陷由此根治）；无命中、不进朗读。
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(hint.startedAt)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(progressColor.opacity(0.30))
                            .frame(width: geo.size.width * remainingFraction(elapsed: elapsed))
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, 4)
        .task(id: hint.receipt.operationID) {
            // 7 秒窗口：只关提示，保存事实已落库。视觉节奏由 TimelineView 按时间自算。
            if isWarning {
                HapticManager.warning()
            }
            try? await Task.sleep(for: .seconds(undoWindow))
            onExpire()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("habit.feedback.container")
    }

    // MARK: 倒计时条时间插值（纯函数）

    /// 剩余比例：从满开始随已过时间线性走到 0（右→左收）
    private func remainingFraction(elapsed: TimeInterval) -> Double {
        max(1 - elapsed / undoWindow, 0)
    }
}
