//
//  HoloAIEntryHint.swift
//  Holo
//
//  首页一次性 HoloAI 入口提示气泡。
//  仅在本次轻量 onboarding 完成回调后出现一次，指向底部导航栏中央按钮。
//

import SwiftUI

/// 一次性 HoloAI 入口提示气泡。
///
/// 纯展示组件：点击由外部 `onTap` 处理（用于关闭提示并进入 Chat）。
/// Reduce Motion 开启时只使用淡入，不附带缩放位移。
struct HoloAIEntryHint: View {

    var onTap: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Text("从这里告诉 Holo 一件事，例如：“午饭花了 35 元”")
                .font(.holoLabel)
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.holoPrimary)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .overlay(alignment: .bottom) {
                    HintBubbleTail()
                        .fill(Color.holoPrimary)
                        .frame(width: 12, height: 7)
                        .offset(y: 7)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .accessibilityElement()
                .accessibilityLabel("从这里告诉 Holo 一件事，例如：午饭花了 35 元")
                .accessibilityHint("点击进入 HoloAI 对话")
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
    }
}

/// 气泡底部小尖角，指向下方的 HoloAI 按钮。
private struct HintBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
