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
    @ObservedObject private var memorySettings = HoloMemorySettings.shared
    @ObservedObject private var growthService = HoloGrowthService.shared
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName

    let onPlanGoal: () -> Void
    let onOpenMemoryGallery: () -> Void
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    @Binding var pendingGoalDetailId: UUID?

    /// 自定义关闭动作（iPad v2 页面层传入：关层并把侧边栏切回「今天」）。
    /// 未传入（sheet / 主 tab 场景）时走系统 dismiss。
    let onClose: (() -> Void)?

    // 个人档案 sheet
    @State private var showProfileEditor = false
    @State private var showUserProfileEditor = false
    @State private var showSettings = false
    @State private var showGoalList = false
    @State private var showMemorySummaryCapsule = false
    @State private var showMemoryConfirmationQueue = false
    @State private var memoryInboxSnapshot = HoloMemoryInboxSnapshot(
        newMemoryCount: 0,
        pendingConfirmationCount: 0,
        hasUnreadMigrationSummary: false
    )

    init(
        onPlanGoal: @escaping () -> Void = {},
        onOpenMemoryGallery: @escaping () -> Void = {},
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        pendingGoalDetailId: Binding<UUID?> = .constant(nil),
        onClose: (() -> Void)? = nil
    ) {
        self.onPlanGoal = onPlanGoal
        self.onOpenMemoryGallery = onOpenMemoryGallery
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self._pendingGoalDetailId = pendingGoalDetailId
        self.onClose = onClose
    }

    /// 统一关闭入口
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    identityHeader
                    plusSection
                    personalContentSection
                    profileSection
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
                // 通宵冲刺 D6（B-P1-1）：iPad 限宽居中为设置型阅读列；iPhone 直通
                .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoToolBackground)
            // 手势必须挂在 NavigationStack 内部：挂栈外时让位判断（沿响应链向上找
            // UINavigationController）恒失效，子页面 push 后右滑会把整个个人页连同
            // 子页一起关掉（2026-09-16 健康页睡眠详情同款事故，见 SwipeBackModifier 文档）。
            // 挂栈内后：根层右滑=关闭个人页；子页面（系统导航栏可见）push 时自动让位给系统返回。
            .swipeBackToDismiss { close() }
            .navigationTitle("个人")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navLeading) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("关闭个人页")
                }
                ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("设置")
                    .accessibilityIdentifier("personal.settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(onReturnHome: {
                    showSettings = false
                    close()
                })
            }
            .sheet(isPresented: $showProfileEditor) {
                NavigationStack {
                    HoloProfileEditorView()
                }
            }
            .sheet(isPresented: $showUserProfileEditor) {
                UserProfileEditorView()
            }
            .navigationDestination(isPresented: $showGoalList) {
                GoalListView(
                    onPlanGoal: onPlanGoal,
                    onOpenLinkedEntity: onOpenLinkedEntity,
                    pendingGoalDetailId: $pendingGoalDetailId
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showMemorySummaryCapsule, !memoryInboxSnapshot.isEmpty {
                memorySummaryCapsule
                    .padding(HoloSpacing.md)
            }
        }
        .animation(HoloAnimation.standard, value: showMemorySummaryCapsule)
        .sheet(isPresented: $showMemoryConfirmationQueue) {
            MemoryConfirmationQueueView(
                onRecordHandled: { _ in
                    Task { await refreshMemoryInbox(presentIfAllowed: false) }
                },
                onQueueDrained: {
                    Task { await refreshMemoryInbox(presentIfAllowed: false) }
                }
            )
        }
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
        .task { await refreshMemoryInbox(presentIfAllowed: true) }
        .task { await HoloSubscriptionService.shared.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .holoMemoryReceiptsDidChange)) { _ in
            Task { await refreshMemoryInbox(presentIfAllowed: false) }
        }
    }

    // MARK: - 身份与会员

    private var identityHeader: some View {
        Button {
            showUserProfileEditor = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                UserAvatarView(size: 64)
                    .fixedSize()
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text(UserDisplayNameSettings.isDisplayNameSet(userName) ? userName : String(localized: "我的资料"))
                        .holoText(.sectionTitle)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("编辑头像与昵称")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HoloSettingsChevron()
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("personal.profile")
    }

    private var plusSection: some View {
        NavigationLink {
            HoloMembershipCenterView()
        } label: {
            PersonalMembershipCard(isPlusActive: entitlementState.isPlusActive)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("personal.membership")
    }

    // MARK: - 我的内容

    private var personalContentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("我的内容")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)

            VStack(spacing: 0) {
                Button {
                    showGoalList = true
                } label: {
                    entryLabel(icon: "target", title: "我的目标", subtitle: "查看目标与进展")
                }
                .accessibilityIdentifier("personal.goals")

                SettingsRowDivider()

                NavigationLink {
                    if HoloMemoryCenterRollout.isEnabled {
                        HoloMemoryCenterView()
                    } else {
                        PersonalMemorySettingsView(onOpenMemoryGallery: onOpenMemoryGallery)
                    }
                } label: {
                    entryLabel(
                        icon: "brain.head.profile",
                        title: "Holo 记住的你",
                        subtitle: memoryInboxSnapshot.isEmpty ? memoryStatusText : memoryInboxSnapshot.summaryText
                    )
                }
                .accessibilityIdentifier("personal.memory")

                SettingsRowDivider()

                NavigationLink {
                    HoloGrowthView(onOpenModule: { target in
                        close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onOpenLinkedEntity(target) }
                    })
                } label: {
                    entryLabel(icon: "leaf", title: "我的积累", subtitle: growthSummary)
                }
                .accessibilityIdentifier("personal.growth")
            }
            .buttonStyle(.plain)
            .holoSurface()
        }
    }

    private var growthSummary: String {
        guard let snapshot = growthService.snapshot else { return String(localized: "记录统计与成长里程碑") }
        return String(localized: "已记录 \(snapshot.recordedDays) 天 · 查看里程碑")
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("让 Holo 了解你")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)

            SettingsNavRow(
                icon: "person.text.rectangle",
                iconColor: .holoInfo,
                title: "个人档案",
                subtitle: profileService.hasProfile ? profileService.previewText : String(localized: "填写角色与偏好，让回复更贴合你"),
                value: profileService.hasProfile ? String(localized: "已填写") : nil
            ) {
                showProfileEditor = true
            }
            .holoSurface()
            .accessibilityIdentifier("personal.aiProfile")
        }
    }

    private func entryLabel(icon: String, title: String, subtitle: String) -> some View {
        HoloSettingsRow(icon: icon, title: title, subtitle: subtitle) {
            HoloSettingsChevron()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.xs)
    }

    private var memorySummaryCapsule: some View {
        HStack(spacing: HoloSpacing.xs) {
            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showMemorySummaryCapsule = false
                if !HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled,
                   memoryInboxSnapshot.pendingConfirmationCount > 0 {
                    showMemoryConfirmationQueue = true
                } else {
                    // 收件箱下线后（含一次性首启说明）直达长廊，不再绕道确认队列。
                    DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: true))
                }
            } label: {
                Label(memoryInboxSnapshot.presentationText, systemImage: "brain.head.profile")
                    .holoText(.metadata)
                    .frame(minHeight: 44)
                    .foregroundColor(.holoToolText)
            }
            .buttonStyle(.plain)

            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showMemorySummaryCapsule = false
                Task { await refreshMemoryInbox(presentIfAllowed: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起记忆提示")
        }
        .padding(.leading, HoloSpacing.md)
        .padding(.trailing, HoloSpacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @MainActor
    private func refreshMemoryInbox(presentIfAllowed: Bool) async {
        memoryInboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
        guard presentIfAllowed,
              !memoryInboxSnapshot.isEmpty,
              HoloMemoryReceiptStore.shouldPresentSummary() else { return }
        HoloMemoryReceiptStore.markSummaryPresented()
        showMemorySummaryCapsule = true
    }

    private var memoryStatusText: String {
        switch (memorySettings.automaticMemoryEnabled, memorySettings.memoryAssistedAnsweringEnabled) {
        case (true, true): return String(localized: "自动整理，并在回答中帮助理解你")
        case (true, false): return String(localized: "自动整理，回答时暂不使用")
        case (false, true): return String(localized: "不再新增，回答可使用已有记忆")
        case (false, false): return String(localized: "记忆功能已关闭")
        }
    }


}

#Preview {
    PersonalView()
}
