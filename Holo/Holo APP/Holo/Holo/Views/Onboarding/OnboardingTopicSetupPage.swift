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
                Text("想从哪些方向开始？")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                Text("可以先选几个方向，也可以直接跳过——主题会从你的想法里长出来，Holo 攒够同类想法后会建议你建立主题。")
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

            OnboardingPrimaryButton(title: selectedTopics.isEmpty ? "先不选，之后再说" : "继续") {
                onContinue()
            }
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

