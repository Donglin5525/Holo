//
//  HabitRecordFeedbackView.swift
//  Holo
//
//  页面内撤销/错误反馈条（2026-10 重构，方案 §11.3）：
//  safeAreaInset 挂在底部导航之上，不使用全局 overlay window toast。
//  计时只决定提示可见性，不决定保存时机。
//

import SwiftUI

struct HabitRecordFeedbackView: View {

    let hint: HabitModuleViewModel.UndoHint
    var onUndo: () -> Void
    var onExpire: () -> Void

    private let undoWindow: TimeInterval = 7

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(.holoPrimary)
                .accessibilityHidden(true)

            Text(String(localized: "已记录"))
                .holoText(.body)
                .foregroundColor(.holoToolText)

            Spacer()

            Button {
                onUndo()
            } label: {
                Text(String(localized: "撤销"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.feedback.undo")
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.holoToolSurface)
                .shadow(color: HoloShadow.card, radius: 12, x: 0, y: 4)
        )
        .overlay {
            // 装饰性暖光条：无命中、不进朗读（方案 §11.2）
            GeometryReader { geo in
                Capsule()
                    .fill(Color.holoPrimary.opacity(0.18))
                    .frame(width: geo.size.width, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: progress, anchor: .leading)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, 4)
        .task(id: hint.receipt.operationID) {
            // 7 秒窗口：只关提示，保存事实已落库
            progress = 1
            withAnimation(.linear(duration: undoWindow)) { progress = 0 }
            try? await Task.sleep(for: .seconds(undoWindow))
            onExpire()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("habit.feedback.container")
    }

    @State private var progress: CGFloat = 1
}
