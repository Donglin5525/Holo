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
            .navigationDestination(for: PromptManager.PromptType.self) { type in
                PromptEditorView(promptType: type)
            }
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
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("Prompt 工坊")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 0) {
                ForEach(PromptManager.PromptType.allCases, id: \.rawValue) { type in
                    NavigationLink(value: type) {
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

#Preview {
    PersonalView()
}
