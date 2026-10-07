//
//  TaskPaperMotionViews.swift
//  Holo
//
//  任务完成动效组件。
//  稳定界面使用 Holo 共同视觉骨架，纸页的收起、上浮和落定只保留在完成瞬间。
//

import SwiftUI

// MARK: - 今日任务状态头

/// 不依赖进度条的文字状态头，外观与 Holo 其他模块的标准卡片一致。
struct TaskPaperHeaderCard: View {
    let title: String
    let subtitle: String
    var countBadge: String?

    var body: some View {
        HStack(alignment: .center, spacing: HoloSpacing.md) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 38, height: 38)
                .background(Color.holoPrimary.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if let countBadge {
                Text(countBadge)
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimaryDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.holoPrimary.opacity(0.10), in: Capsule())
                    .fixedSize()
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 完成回执

/// 完成时的一次性动作：轻微收页、上浮并淡出。
/// 视觉使用 Holo 标准卡片和品牌橙，不把纸张主题留在稳定页面中。
struct TaskPaperCompletionReceipt: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ReceiptPhase {
        var opacity: Double = 0
        var offsetY: CGFloat = 25
        var rotation: Double = -4
        var scale: CGFloat = 0.88
    }

    @State private var staticVisible = false
    @State private var dismissed = false

    var body: some View {
        if reduceMotion {
            reducedMotionBody
        } else {
            keyframeBody
        }
    }

    private var reducedMotionBody: some View {
        receiptBody
            .opacity(staticVisible && !dismissed ? 1 : 0)
            .onAppear {
                withAnimation(HoloAnimation.quick) { staticVisible = true }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(0.1, HoloAnimation.paperReceiptDuration - 0.3)
                ) {
                    withAnimation(HoloAnimation.standard) { dismissed = true }
                }
            }
    }

    private var keyframeBody: some View {
        KeyframeAnimator(initialValue: ReceiptPhase()) { phase in
            receiptBody
                .opacity(phase.opacity)
                .offset(y: phase.offsetY)
                .rotationEffect(.degrees(phase.rotation))
                .scaleEffect(phase.scale)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1.0, duration: 0.22)
                LinearKeyframe(1.0, duration: 0.21)
                LinearKeyframe(0.0, duration: 0.32)
            }
            KeyframeTrack(\.offsetY) {
                SpringKeyframe(-8, duration: 0.35, spring: Spring(response: 0.35, dampingRatio: 0.68))
                SpringKeyframe(-42, duration: 0.40, spring: .smooth)
            }
            KeyframeTrack(\.rotation) {
                SpringKeyframe(2, duration: 0.35, spring: Spring(response: 0.35, dampingRatio: 0.68))
                SpringKeyframe(-2, duration: 0.40, spring: .smooth)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.03, duration: 0.35, spring: Spring(response: 0.35, dampingRatio: 0.68))
                SpringKeyframe(0.92, duration: 0.40, spring: .smooth)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "已完成：\(title)"))
    }

    private var receiptBody: some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Color.holoPrimary, in: Circle())
                .shadow(color: Color.holoPrimary.opacity(0.24), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "已完成"))
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)

                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: 340)
        .holoCard()
        .overlay {
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoPrimary.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: Color.holoPrimary.opacity(0.12), radius: 16, y: 7)
    }
}

// MARK: - 统一操作回执

/// 完成、延期等短时可撤回操作共用的 Holo 回执。
struct HoloUndoToast: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)

            Text(message)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: onUndo) {
                Text(String(localized: "撤回"))
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoPrimary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .holoCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message)，\(String(localized: "撤回"))")
    }
}
