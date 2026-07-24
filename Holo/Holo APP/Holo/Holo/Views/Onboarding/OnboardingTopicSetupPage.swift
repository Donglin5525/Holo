//
//  OnboardingTopicSetupPage.swift
//  Holo
//
//  新用户主题边界设置：只写本地 Topic，不依赖 AI 授权或网络。
//

import SwiftUI

struct OnboardingTopicSetupPage: View {
    @Binding var selectedTopics: Set<String>
    let errorMessage: String?
    let onContinue: () -> Void

    @State private var customTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            Spacer(minLength: HoloSpacing.md)

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text("选择你关注的主题")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                Text("HoloAI 只会在这些方向里分类，不再自己发明新的顶层标签。以后可随时修改。")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HoloSpacing.sm) {
                ForEach(allTopics, id: \.self) { title in
                    topicButton(title)
                }
            }

            HStack(spacing: HoloSpacing.sm) {
                TextField("自定义主题", text: $customTitle)
                    .font(.holoBody)
                    .padding(.horizontal, HoloSpacing.md)
                    .frame(minHeight: 46)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Button("添加") { addCustomTopic() }
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .frame(minWidth: 60, minHeight: 44)
                    .disabled(normalizedCustomTitle.isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.holoCaption)
                    .foregroundColor(.holoError)
            }

            Spacer()

            OnboardingPrimaryButton(title: "继续") {
                onContinue()
            }
            .disabled(selectedTopics.isEmpty)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.xl)
    }

    private var allTopics: [String] {
        let custom = selectedTopics.filter { !ThoughtThemeConstraint.presetTopics.contains($0) }.sorted()
        return ThoughtThemeConstraint.presetTopics + custom
    }

    private var normalizedCustomTitle: String {
        ThoughtTagNormalizer.displayName(customTitle)
    }

    private func addCustomTopic() {
        let title = normalizedCustomTitle
        guard !title.isEmpty,
              ThoughtTagNormalizer.key(title) != ThoughtTagNormalizer.key(ThoughtThemeConstraint.unclassifiedTitle)
        else { return }
        selectedTopics.insert(title)
        customTitle = ""
        HapticManager.light()
    }

    private func topicButton(_ title: String) -> some View {
        let isSelected = selectedTopics.contains(title)
        return Button {
            if isSelected {
                selectedTopics.remove(title)
            } else {
                selectedTopics.insert(title)
            }
            HapticManager.light()
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.holoCaption)
            .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)
            .padding(.horizontal, HoloSpacing.md)
            .frame(minHeight: 48)
            .background(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(isSelected ? "已选择" : "未选择")")
    }
}

