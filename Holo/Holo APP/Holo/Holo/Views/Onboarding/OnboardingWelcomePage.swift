//
//  OnboardingWelcomePage.swift
//  Holo
//
//  轻量新人引导第一页：认识 Holo + 选填昵称。
//  合并原首页单独的昵称 Alert。
//

import SwiftUI

/// 轻量 onboarding 第一页。
struct OnboardingWelcomePage: View {

    @Binding var nicknameDraft: String
    let onContinue: () -> Void

    @FocusState private var isNicknameFocused: Bool

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.xl) {
                    Spacer().frame(height: HoloSpacing.xxl)

                    Text("你好，我是 Holo")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    Text("你的个人数据助理。帮你记录生活、安排事情，并慢慢看见自己的变化。")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("希望我怎么称呼你？（选填）")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        TextField("例如：小满", text: $nicknameDraft)
                            .focused($isNicknameFocused)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(HoloSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoCardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .stroke(Color.holoBorder, lineWidth: 1)
                            )
                            .accessibilityLabel("昵称")
                    }
                    .padding(.top, HoloSpacing.md)
                }
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.bottom, HoloSpacing.xxl)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton(title: "继续") {
                isNicknameFocused = false
                onContinue()
            }
            .padding(.horizontal, HoloSpacing.xl)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.lg)
            .background(Color.holoBackground)
        }
    }
}
