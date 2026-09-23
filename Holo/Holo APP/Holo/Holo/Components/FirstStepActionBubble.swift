//
//  FirstStepActionBubble.swift
//  Holo
//
//  新用户「第一步行动卡」（拍板方案 C）：悬浮在底栏中央 AI 按钮上方的指引气泡 + 虚线光圈。
//  挂载于 BottomNavBar 的 overlay（居中对齐），随宿主判定显隐：
//  点气泡 → 跳 AI 对话并预填示例句（只预填不发送）；✕ 手动关闭落盘；产生首条记录后自动消失。
//

import SwiftUI

struct FirstStepActionBubble: View {

    var onTap: () -> Void
    var onDismiss: () -> Void

    @State private var haloRotation: Double = 0

    var body: some View {
        ZStack {
            // 虚线光圈：套在凸起的 AI 按钮上。
            // 底栏内容行高 56、按钮上浮 24 → 按钮圆心在栏几何中心上方 24pt；不拦截点击。
            Circle()
                .strokeBorder(
                    Color.holoPrimary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])
                )
                .frame(width: 86, height: 86)
                .offset(y: -24)
                .rotationEffect(.degrees(haloRotation))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            bubble
                .offset(y: -80)
        }
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                haloRotation = 360
            }
        }
    }

    private var bubble: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                VStack(spacing: 2) {
                    Text(String(localized: "对 Holo 说一句话试试"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                    Text(String(localized: "比如“午饭花了 35 元”"))
                        .font(.system(size: 11.5))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstStepBubble.main")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.55))
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "关闭新手引导"))
            .accessibilityIdentifier("firstStepBubble.dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.holoCardBackground)
                .overlay(alignment: .bottom) {
                    // 朝下小尾巴，指向 AI 按钮
                    Rectangle()
                        .fill(Color.holoCardBackground)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(45))
                        .offset(y: 7)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 18, y: 6)
        )
    }
}

#Preview {
    FirstStepActionBubble(onTap: {}, onDismiss: {})
        .padding(.top, 200)
        .background(Color.holoBackground)
}
