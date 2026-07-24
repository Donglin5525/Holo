//
//  HoloLightweightOnboardingView.swift
//  Holo
//
//  轻量新人引导 V1 主容器。
//  协调四页切换与完成回调；主题页只创建本地 Topic，不发起网络请求。
//

import SwiftUI

/// 轻量新人引导 V1 主容器。
///
/// 四页结构：认识 Holo（选填昵称）→ 功能与使用方式 → 主题设置 → AI 数据处理授权。
/// 关闭前由 `finish(_:)` 统一处理昵称保存、旧 onboarding 标记、consent 授权与
/// 轻量 completed key 写入，再通过 `onComplete` 回调通知宿主关闭并触发一次 AI 入口提示。
struct HoloLightweightOnboardingView: View {

    /// 完成回调。无论同意、暂不授权还是跳过，都会调用一次，宿主据此关闭引导并安排 AI 入口提示。
    let onComplete: (OnboardingCompletionChoice) -> Void

    @State private var currentPage: Int = 0
    @State private var nicknameDraft: String = ""
    @State private var selectedTopics = ThoughtThemeConstraint.defaultPresetTopics
    @State private var topicSetupError: String?

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                pageContent
            }
        }
        .preferredColorScheme(DarkModeManager.shared.colorScheme)
    }

    // MARK: - 顶部栏（页码圆点 + 跳过）

    private var topBar: some View {
        ZStack {
            OnboardingPageDots(currentPage: currentPage, pageCount: 4)

            HStack(spacing: 0) {
                Spacer()
                if currentPage < 3 {
                    Button {
                        finish(.skippedOnboarding)
                    } label: {
                        Text("跳过")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .frame(minHeight: 44)
                            .padding(.horizontal, HoloSpacing.sm)
                    }
                    .accessibilityLabel("跳过引导")
                }
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
        .frame(height: 44)
    }

    // MARK: - 页面内容

    @ViewBuilder
    private var pageContent: some View {
        switch currentPage {
        case 0:
            OnboardingWelcomePage(nicknameDraft: $nicknameDraft) {
                withAnimation(.easeInOut(duration: 0.25)) { currentPage = 1 }
            }
        case 1:
            OnboardingCapabilitiesPage {
                withAnimation(.easeInOut(duration: 0.25)) { currentPage = 2 }
            }
        case 2:
            OnboardingTopicSetupPage(
                selectedTopics: $selectedTopics,
                errorMessage: topicSetupError,
                onContinue: saveTopicsAndContinue
            )
        default:
            OnboardingAIConsentPage(
                onGrant: { finish(.grantedAIConsent) },
                onSkipConsent: { finish(.skippedAIConsent) }
            )
        }
    }

    private func saveTopicsAndContinue() {
        do {
            _ = try TopicRepository().createClassificationTopics(titles: Array(selectedTopics))
            topicSetupError = nil
            withAnimation(.easeInOut(duration: 0.25)) { currentPage = 3 }
        } catch {
            topicSetupError = "主题保存失败，请再试一次"
        }
    }

    // MARK: - 完成处理

    /// 统一收尾：保存昵称（仅非整体跳过）、标记旧 onboarding、按选择授权、写 completed key、回调。
    private func finish(_ choice: OnboardingCompletionChoice) {
        // 1. 仅在非整体跳过时保存昵称草稿；跳过不保存半输入昵称。
        if choice != .skippedOnboarding,
           let name = UserDisplayNameSettings.normalizedDisplayName(nicknameDraft) {
            UserDisplayNameSettings.standard.saveDisplayName(name)
        }
        // 2. 完成/跳过都标记旧昵称 onboarding，避免旧 Alert 再次出现。
        UserDisplayNameSettings.standard.markOnboardingCompleted()
        // 3. 仅在「同意并开始使用」时授予 AI 数据处理授权。
        if choice == .grantedAIConsent {
            HoloAIDataProcessingConsent.shared.grant()
        }
        // 4. 写入轻量 onboarding completed key。
        LightweightOnboardingSettings.markCompleted()
        // 5. 回调：关闭 onboarding 并触发一次 AI 入口提示。
        onComplete(choice)
    }
}

// MARK: - 共享子组件

/// 主按钮：全宽、最小高度 50pt、holoPrimary。
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.holoBody)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .accessibilityLabel(title)
    }
}

/// 次级文字按钮：低视觉权重，触控高度不低于 44pt。
struct OnboardingSecondaryTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(minHeight: 44)
        }
        .accessibilityLabel(title)
    }
}

/// 页码圆点：只表示当前位置，不显示百分比。
struct OnboardingPageDots: View {
    let currentPage: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.holoPrimary : Color.holoBorder)
                    .frame(
                        width: index == currentPage ? 8 : 6,
                        height: index == currentPage ? 8 : 6
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentPage)
        .accessibilityElement()
        .accessibilityLabel("第 \(currentPage + 1) 步，共 \(pageCount) 步")
    }
}
