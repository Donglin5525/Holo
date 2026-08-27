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

    // 个人档案 sheet
    @State private var showProfileEditor = false
    @State private var showGoalList = false
    @State private var showMemorySettings = false
    @State private var showMemorySummaryCapsule = false
    @State private var showMemoryConfirmationQueue = false
    // 昵称修改弹窗
    @State private var showNicknameEditor = false
    @State private var nicknameDraft = ""
    @State private var memoryInboxSnapshot = HoloMemoryInboxSnapshot(
        newMemoryCount: 0,
        pendingConfirmationCount: 0,
        hasUnreadMigrationSummary: false
    )

    init(
        onPlanGoal: @escaping () -> Void = {},
        onOpenMemoryGallery: @escaping () -> Void = {},
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        pendingGoalDetailId: Binding<UUID?> = .constant(nil)
    ) {
        self.onPlanGoal = onPlanGoal
        self.onOpenMemoryGallery = onOpenMemoryGallery
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self._pendingGoalDetailId = pendingGoalDetailId
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    plusSection
                    profileSection
                    goalsSection
                    memorySection
                    #if DEBUG
                    developerToolsSection
                    #endif
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
            .alert("怎么称呼你", isPresented: $showNicknameEditor) {
                TextField("昵称", text: $nicknameDraft)
                Button("保存") { saveNickname() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("保存后随 iCloud 同步，卸载重装也能找回来")
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
        .animation(.easeInOut(duration: 0.2), value: showMemorySummaryCapsule)
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
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .fill(HoloPlusTheme.darkGradient)

                Circle()
                    .fill(HoloPlusTheme.glowColor)
                    .frame(width: 120, height: 120)
                    .blur(radius: 28)
                    .offset(x: 34, y: -44)

                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    HStack(alignment: .top, spacing: HoloSpacing.md) {
                        HoloPlusEmblem(size: 58)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: HoloSpacing.xs) {
                                Text("Holo Plus")
                                    .font(.holoTitle)
                                    .foregroundColor(HoloPlusTheme.accentText)

                                if entitlementState.isPlusActive {
                                    Text("已生效")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(HoloPlusTheme.badgeText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(HoloPlusTheme.badgeBg)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(
                                entitlementState.isPlusActive
                                    ? "更高额度已为你开启"
                                    : "解锁 AI、语音与记忆洞察额度"
                            )
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(HoloPlusTheme.subtleText)
                            .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: HoloSpacing.sm) {
                        plusFeaturePill(
                            "HoloAI",
                            value: entitlementState.isPlusActive ? "30/天" : "15/天"
                        )
                        plusFeaturePill(
                            "语音识别",
                            value: entitlementState.isPlusActive ? "50/天" : "20/天"
                        )
                        plusFeaturePill(
                            "任务",
                            value: entitlementState.isPlusActive ? "50/天" : "20/天"
                        )
                    }

                    HStack(spacing: HoloSpacing.xs) {
                        Text(entitlementState.isPlusActive ? "查看会员权益" : "进入会员中心")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(HoloPlusTheme.accentText)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(HoloPlusTheme.accentText.opacity(0.82))
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .stroke(HoloPlusTheme.strokeColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: 12)
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
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showProfileEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
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

            // 昵称：原先只在引导页设置一次、之后无处可改；
            // 昵称云同步上线后这里同时是改名入口与云端值的写通道。
            Button {
                nicknameDraft = userName
                showNicknameEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("昵称")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text("首页问候怎么称呼你，随 iCloud 同步")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    Text(userName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

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

    /// 改名走与引导页同一条双写通道：本地立即生效 + 同步表上行 iCloud
    private func saveNickname() {
        guard let name = UserDisplayNameSettings.normalizedDisplayName(nicknameDraft) else { return }
        UserDisplayNameSettings.standard.saveDisplayName(name)
        UserPreferenceRepository.shared.set(name, forKey: UserPreferenceRepository.displayNameKey)
    }

    private var memorySummaryCapsule: some View {
        HStack(spacing: HoloSpacing.xs) {
            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showMemorySummaryCapsule = false
                if memoryInboxSnapshot.pendingConfirmationCount > 0 {
                    showMemoryConfirmationQueue = true
                } else {
                    // 「新记住 N 件」直达长廊洞察 Tab 高亮新记忆，不再绕道设置页。
                    DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: true))
                }
            } label: {
                Label(memoryInboxSnapshot.summaryText, systemImage: "brain.head.profile.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
            }
            .buttonStyle(.plain)

            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showMemorySummaryCapsule = false
                Task { await refreshMemoryInbox(presentIfAllowed: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
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
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
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

    // MARK: - 我的记忆

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("我的记忆")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
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
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)

                        Text(memoryStatusText)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
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
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(.plain)
        }
    }

    private var memoryStatusText: String {
        switch (memorySettings.automaticMemoryEnabled, memorySettings.memoryAssistedAnsweringEnabled) {
        case (true, true): return "自动整理，并在回答中帮助理解你"
        case (true, false): return "自动整理，回答时暂不使用"
        case (false, true): return "不再新增，回答可使用已有记忆"
        case (false, false): return "记忆功能已关闭"
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
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
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
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("验证领域萃取、跨域融合与问题召回")
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
            .buttonStyle(.plain)
        }
    }
    #endif
}

#Preview {
    PersonalView()
}
