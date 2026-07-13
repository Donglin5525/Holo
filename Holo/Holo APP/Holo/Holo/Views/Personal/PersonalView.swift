//
//  PersonalView.swift
//  Holo
//
//  「个人」页面
//  个人档案
//

import SwiftUI

struct PersonalView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileService = HoloProfileService.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName

    let onPlanGoal: () -> Void
    @Binding var pendingGoalDetailId: UUID?

    // 个人档案 sheet
    @State private var showProfileEditor = false
    @State private var showGoalList = false

    init(
        onPlanGoal: @escaping () -> Void = {},
        pendingGoalDetailId: Binding<UUID?> = .constant(nil)
    ) {
        self.onPlanGoal = onPlanGoal
        self._pendingGoalDetailId = pendingGoalDetailId
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    profileSection
                    goalsSection
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
            .sheet(isPresented: $showProfileEditor) {
                NavigationStack {
                    HoloProfileEditorView()
                }
            }
            .navigationDestination(isPresented: $showGoalList) {
                GoalListView(
                    onPlanGoal: onPlanGoal,
                    pendingGoalDetailId: $pendingGoalDetailId
                )
            }
        }
        .swipeBackToDismiss { dismiss() }
        .onAppear {
            _ = profileService.loadProfile()
            if pendingGoalDetailId != nil {
                showGoalList = true
            }
        }
        .onChange(of: pendingGoalDetailId) { _, newValue in
            if newValue != nil {
                showGoalList = true
            }
        }
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

    // MARK: - 我的目标

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "target")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("我的目标")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showGoalList = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "target")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("目标管理")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("查看 HoloAI 为你规划的长期目标")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
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
