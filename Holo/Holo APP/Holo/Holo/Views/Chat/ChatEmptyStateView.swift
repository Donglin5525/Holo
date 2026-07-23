//
//  ChatEmptyStateView.swift
//  Holo
//
//  空会话首屏：欢迎语 + 动态建议问题卡片。
//  仅在「真·空会话」（历史消息加载完成且无消息）时展示，
//  进入对话后自然消失。按 onboarding 状态区分新老用户内容。
//

import SwiftUI

struct ChatEmptyStateView: View {

    @ObservedObject var viewModel: ChatViewModel

    private var isNewUser: Bool { !LightweightOnboardingSettings.isCompleted }

    private var welcomeTitle: String {
        isNewUser ? "你好，我是 Holo" : "想聊点什么？"
    }

    private var welcomeSubtitle: String {
        if isNewUser {
            return "你的个人数据助理。先来认识一下吧——"
        }
        return "挑一个方向，或者直接在下面输入。"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                Spacer(minLength: HoloSpacing.xxl)

                // 欢迎区
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(welcomeTitle)
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    Text(welcomeSubtitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 建议问题卡片
                VStack(spacing: HoloSpacing.sm) {
                    ForEach(viewModel.emptyStateCapabilities) { capability in
                        suggestionCard(for: capability)
                    }
                }

                Spacer(minLength: HoloSpacing.xl)
            }
            .padding(.horizontal, HoloSpacing.md)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.emptyStateCapabilities)
    }

    @ViewBuilder
    private func suggestionCard(for capability: HoloAICapability) -> some View {
        Button {
            viewModel.handleCapabilityTap(capability)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: capability.systemImage)
                    .font(.system(size: 18))
                    .foregroundColor(capability.isEmphasized ? .white : .holoPrimary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(capability.isEmphasized ? Color.holoPrimary : Color.holoPrimary.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(capability.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoTextPrimary)

                    Text(capability.previewPrompt)
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(capability.isEmphasized ? Color.holoPrimary.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .disabled(viewModel.isStreaming || !capability.isEnabled)
        .opacity(capability.isEnabled ? 1.0 : 0.5)
    }
}

private extension HoloAICapability {
    /// 空状态卡片展示的预填提问文案（与 handleCapabilityTap 的预填一致）。
    var previewPrompt: String {
        switch id {
        case .onboarding:
            return "能教我怎么用 Holo 吗？"
        case .todayState:
            return "帮我看看今天的整体状态"
        case .recentAnalysis:
            return "分析一下我最近的数据趋势"
        case .longTermPatterns:
            return "你了解我哪些长期偏好和模式？"
        case .goalPlanning:
            return "帮我规划一个目标"
        }
    }
}
