//
//  OnboardingCapabilitiesPage.swift
//  Holo
//
//  轻量新人引导第二页：一屏讲清「Holo 是什么」。
//  功能深讲已移到预置欢迎笔记（完成引导后深链直达），本页只留最小认知；
//  底部一句预告让用户对即将打开的欢迎笔记有预期，不被自动跳转搞懵。
//

import SwiftUI

/// 轻量 onboarding 第二页。
struct OnboardingCapabilitiesPage: View {

    let onNext: () -> Void

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                Spacer()
                Spacer()

                Text("Holo 是什么")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)

                Text(String(localized: "一个把生活记录在一起的地方——念头、账单、待办、习惯，时间久了，汇成你的记忆。"))
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    capabilityRow(
                        icon: "square.and.pencil",
                        text: String(localized: "一句话记录，不用先找入口"))
                    capabilityRow(
                        icon: "bubble.left.and.text.bubble.right",
                        text: String(localized: "像聊天一样，直接问自己的数据"))
                    capabilityRow(
                        icon: "book.closed",
                        text: String(localized: "生活轨迹串成时间线，方便回看"))
                }
                .padding(.top, HoloSpacing.sm)

                Spacer()
                Spacer()

                Text(String(localized: "进入后有一篇欢迎笔记，带你逛完各个模块"))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, HoloSpacing.md)
            }
            .padding(.horizontal, HoloSpacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton(title: String(localized: "下一步")) { onNext() }
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.lg)
                .background(Color.holoBackground)
        }
    }

    /// 轻要点行：图标 + 一句话（能力卡已随深讲移至欢迎笔记，这里不留卡片）
    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 32, height: 32)
                .background(Color.holoPrimaryLight.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            Text(text)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
