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
    @State private var showGoalList = false
    @State private var showMemorySettings = false
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
                VStack(spacing: HoloSpacing.xl) {
                    profileSection
                    goalsSection
                    memorySection
                    plusSection
                    #if DEBUG
                    developerToolsSection
                    #endif
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                // 通宵冲刺 D6（B-P1-1）：iPad 限宽居中为设置型阅读列；iPhone 直通
                .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoToolBackground)
            // 手势必须挂在 NavigationStack 内部：挂栈外时让位判断（沿响应链向上找
            // UINavigationController）恒失效，子页面 push 后右滑会把整个个人页连同
            // 子页一起关掉（2026-09-16 健康页睡眠详情同款事故，见 SwipeBackModifier 文档）。
            // 挂栈内后：根层右滑=关闭个人页；子页面（系统导航栏可见）push 时自动让位给系统返回。
            .swipeBackToDismiss { dismiss() }
            .navigationTitle("个人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
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
            .navigationDestination(isPresented: $showMemorySettings) {
                PersonalMemorySettingsView(onOpenMemoryGallery: onOpenMemoryGallery)
            }
        }
        .overlay(alignment: .top) {
            if showMemorySummaryCapsule, !memoryInboxSnapshot.isEmpty {
                memorySummaryCapsule
                    .padding(.top, 52)
                    .padding(.horizontal, HoloSpacing.lg)
                    .transition(.move(edge: .top).combined(with: .opacity))
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

    // MARK: - Holo Plus

    private var plusSection: some View {
        NavigationLink {
            HoloMembershipCenterView()
        } label: {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                HoloPlusEmblem(size: 36, tier: entitlementState.isPlusActive ? .plus : .free)
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text(entitlementState.isPlusActive ? "Holo Plus" : String(localized: "免费版"))
                        .holoText(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.holoToolText)
                    Text(entitlementState.isPlusActive ? String(localized: "查看会员权益") : String(localized: "升级解锁 2 倍 AI 额度与全部小组件"))
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(HoloSpacing.md)
            .holoSurface()
        }
        .buttonStyle(.plain)
    }

    private func plusFeaturePill(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(HoloPlusTheme.subtleText)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(HoloPlusTheme.accentText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.holoPrimary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 个人档案

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("个人档案")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            Button {
                showProfileEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(profileService.hasProfile
                                  ? Color.holoSuccess.opacity(0.1)
                                  : Color.holoToolTextSecondary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: profileService.hasProfile ? "checkmark.shield.fill" : "shield")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(profileService.hasProfile ? .holoSuccess : .holoToolTextSecondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileService.hasProfile ? String(localized: "已配置") : String(localized: "未配置"))
                            .holoText(.body)
                            .foregroundColor(.holoToolText)

                        if profileService.hasProfile {
                            Text(profileService.previewText)
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                                .lineLimit(1)
                        } else {
                            Text("让 AI 了解你，获得更个性化的回复")
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(PlainButtonStyle())

            // 用户身份资料：与设置页复用同一编辑器和同一同步状态。
            Button {
                showUserProfileEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    UserAvatarView(size: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("个人资料")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)

                        Text("头像与昵称，随 iCloud 同步")
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer()

                    Text(UserDisplayNameSettings.displayOrPlaceholder(userName))
                        .holoText(.body)
                        .foregroundColor(.holoToolTextSecondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(PlainButtonStyle())
        }
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
                Label(memoryInboxSnapshot.presentationText, systemImage: "brain.head.profile.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoToolText)
            }
            .buttonStyle(.plain)

            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showMemorySummaryCapsule = false
                Task { await refreshMemoryInbox(presentIfAllowed: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
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

    // MARK: - 我的目标

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "target")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("我的目标")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            Button {
                showGoalList = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "target")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("目标管理")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                        Text("查看 HoloAI 为你规划的长期目标")
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 长期记忆

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("长期记忆")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            NavigationLink {
                PersonalMemorySettingsView(onOpenMemoryGallery: onOpenMemoryGallery)
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Holo 记住的你")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)

                        Text(memoryStatusText)
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(2)

                        if !memoryInboxSnapshot.isEmpty {
                            Text(memoryInboxSnapshot.summaryText)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.holoPrimary.opacity(0.1))
                                .clipShape(Capsule())
                                .padding(.top, 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(.plain)
        }
    }

    private var memoryStatusText: String {
        switch (memorySettings.automaticMemoryEnabled, memorySettings.memoryAssistedAnsweringEnabled) {
        case (true, true): return String(localized: "自动整理，并在回答中帮助理解你")
        case (true, false): return String(localized: "自动整理，回答时暂不使用")
        case (false, true): return String(localized: "不再新增，回答可使用已有记忆")
        case (false, false): return String(localized: "记忆功能已关闭")
        }
    }

    #if DEBUG
    // MARK: - 开发者工具

    private var developerToolsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "hammer")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("开发者工具")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            NavigationLink {
                AIMemoryLabView()
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "testtube.2")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 记忆实验室")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                        Text("验证领域萃取、跨域融合与问题召回")
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(.plain)
        }
    }
    #endif
}

#Preview {
    PersonalView()
}
