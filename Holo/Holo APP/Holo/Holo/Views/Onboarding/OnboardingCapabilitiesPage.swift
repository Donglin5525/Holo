//
//  OnboardingCapabilitiesPage.swift
//  Holo
//
//  轻量新人引导第二页：三个核心使用动作（记录 / 查询 / 回看）。
//  仅静态说明，不发送消息或创建数据。
//

import SwiftUI

/// 轻量 onboarding 第二页。
struct OnboardingCapabilitiesPage: View {

    let onNext: () -> Void

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    Spacer().frame(height: HoloSpacing.xl)

                    Text("你可以这样使用 Holo")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    OnboardingCapabilityCard(
                        icon: "square.and.pencil",
                        title: "一句话记录",
                        description: "不用先找入口，直接告诉 Holo 发生了什么。",
                        example: "“午饭花了 35 元”",
                        footnote: "还可以创建待办、记录想法、习惯打卡。"
                    )

                    OnboardingCapabilityCard(
                        icon: "bubble.left.and.text.bubble.right",
                        title: "直接问自己的数据",
                        description: "想知道最近的情况，直接用自然语言提问。",
                        example: "“这个月餐饮花了多少？”",
                        footnote: nil
                    )

                    OnboardingCapabilityCard(
                        icon: "book.closed",
                        title: "回看生活变化",
                        description: "记忆长廊会把不同模块的记录串成时间线，方便回看。",
                        example: "财务、待办、习惯和想法会出现在同一段生活轨迹中。",
                        footnote: nil
                    )
                }
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.bottom, HoloSpacing.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton(title: "下一步") { onNext() }
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.lg)
                .background(Color.holoBackground)
        }
    }
}

// MARK: - 能力卡

/// 能力卡：图标 + 标题 + 说明 + 示例（引文样式）+ 可选补充小字。
struct OnboardingCapabilityCard: View {
    let icon: String
    let title: String
    let description: String
    let example: String
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.holoPrimaryLight.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Text(title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
            }

            Text(description)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(example)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, HoloSpacing.md)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.holoPrimary.opacity(0.4))
                        .frame(width: 3)
                }

            if let footnote {
                Text(footnote)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .accessibilityElement(children: .combine)
    }
}
