//
//  OnboardingAIConsentPage.swift
//  Holo
//
//  轻量新人引导第四页：HoloAI 数据处理授权说明与选择。
//

import SwiftUI

/// 轻量 onboarding 第四页。
struct OnboardingAIConsentPage: View {

    let onGrant: () -> Void
    let onSkipConsent: () -> Void

    @State private var showPrivacyPolicy = false

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    Spacer().frame(height: HoloSpacing.xl)

                    Text("开始前，确认一项授权")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    Text("当你使用 HoloAI、AI 洞察、语音转文字，或另行开启“自动形成记忆”时，完成该功能所需的问题，以及财务、习惯、待办、观点、健康摘要或语音片段，会经 Holo 后端发送给第三方 AI 或语音服务处理。")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        consentBullet("只在你使用相关 AI 功能，或主动开启自动形成记忆后处理必要数据。")
                        consentBullet("不授权也可以继续使用本地记账、待办、习惯和观点功能。")
                        consentBullet("之后可以在 HoloAI 数据授权中随时开启或撤回。")
                    }
                    .padding(HoloSpacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .fill(Color.holoCardBackground)
                    )

                    Button {
                        showPrivacyPolicy = true
                    } label: {
                        Text("查看隐私政策")
                            .font(.holoCaption)
                            .foregroundColor(.holoPrimary)
                            .underline()
                    }
                    .accessibilityLabel("查看隐私政策")
                }
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.bottom, HoloSpacing.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HoloSpacing.sm) {
                OnboardingPrimaryButton(title: "同意并开始使用") { onGrant() }
                OnboardingSecondaryTextButton(title: "暂不授权，先进入 Holo") { onSkipConsent() }
            }
            .padding(.horizontal, HoloSpacing.xl)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.lg)
            .background(Color.holoBackground)
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            LegalDocumentSheet(documentType: .privacyPolicy)
        }
    }

    // MARK: - 授权说明条目

    private func consentBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.holoPrimary)
                .frame(width: 16)
                .padding(.top, 2)

            Text(text)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
