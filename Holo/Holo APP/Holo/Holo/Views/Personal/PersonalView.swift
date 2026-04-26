//
//  PersonalView.swift
//  Holo
//
//  「个人」页面
//  Prompt 工坊 + 个人档案两大板块
//

import SwiftUI

struct PersonalView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileService = HoloProfileService.shared
    @AppStorage("userName") private var userName: String = "东林"

    // Prompt 编辑器 sheet
    @State private var selectedPromptType: PromptManager.PromptType?
    @State private var showPromptEditor = false

    // 个人档案 sheet
    @State private var showProfileEditor = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    promptWorkshopSection
                    profileSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("个人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            // Prompt 编辑器（sheet 形式）
            .sheet(item: $selectedPromptType) { type in
                // 使用 fullScreenCover 包裹，隔离 PromptEditorView 的 @StateObject 初始化
                PromptEditorWrapper(promptType: type)
            }
            // 个人档案编辑器
            .sheet(isPresented: $showProfileEditor) {
                NavigationStack {
                    HoloProfileEditorView()
                }
            }
        }
        .swipeBackToDismiss { dismiss() }
        .onAppear {
            _ = profileService.loadProfile()
        }
    }

    // MARK: - Prompt 工坊

    private var promptWorkshopSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // Section 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("Prompt 工坊")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // Prompt 列表卡片
            VStack(spacing: 0) {
                ForEach(PromptManager.PromptType.allCases, id: \.rawValue) { type in
                    Button {
                        selectedPromptType = type
                    } label: {
                        promptRow(type)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if type != PromptManager.PromptType.allCases.last {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 单条 Prompt 行
    private func promptRow(_ type: PromptManager.PromptType) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.holoPrimary.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: type.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(type.displayDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            if PromptManager.shared.isCustomized(type) {
                Text("已自定义")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }

    // MARK: - 个人档案

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("个人档案")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showProfileEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(profileService.hasProfile
                                  ? Color.holoSuccess.opacity(0.1)
                                  : Color.holoTextSecondary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: profileService.hasProfile ? "checkmark.shield.fill" : "shield")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(profileService.hasProfile ? .holoSuccess : .holoTextSecondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileService.hasProfile ? "已配置" : "未配置")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        if profileService.hasProfile {
                            Text(profileService.previewText)
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(1)
                        } else {
                            Text("让 AI 了解你，获得更个性化的回复")
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - PromptType Identifiable conformance (for .sheet(item:))

extension PromptManager.PromptType: Identifiable {
    public var id: String { rawValue }
}

// MARK: - PromptEditorWrapper

/// 延迟初始化 PromptEditorView 的包装器
/// 避免 @StateObject 在 sheet 呈现时立即创建 ViewModel 导致栈溢出
struct PromptEditorWrapper: View {
    let promptType: PromptManager.PromptType
    @State private var showEditor = false

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()
            ProgressView("加载中...")
                .tint(.holoPrimary)
        }
        .onAppear {
            // 延迟到下一个 RunLoop 再设置，让 sheet 完成呈现动画
            DispatchQueue.main.async {
                showEditor = true
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            NavigationStack {
                PromptEditorView(promptType: promptType)
            }
            .preferredColorScheme(DarkModeManager.shared.colorScheme)
        }
    }
}

// MARK: - Preview

#Preview {
    PersonalView()
}
