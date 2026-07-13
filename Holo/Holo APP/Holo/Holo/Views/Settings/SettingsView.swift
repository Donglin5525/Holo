//
//  SettingsView.swift
//  Holo
//
//  设置页面 - 包含深色模式等设置项
//  从首页右上角人头像按钮进入
//

import SwiftUI
import CloudKit
import OSLog
import AuthenticationServices

// MARK: - SettingsView

/// 设置页面
struct SettingsView: View {

    // MARK: - Environment

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var systemColorScheme

    // MARK: - Observed Objects

    @ObservedObject private var darkModeManager = DarkModeManager.shared
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared
    @ObservedObject private var memorySettings = HoloMemorySettings.shared
    @ObservedObject private var iCloudSyncStatus = ICloudSyncStatusService.shared
    @ObservedObject private var authService = AppleSignInAuthService.shared
    @ObservedObject private var storageService = StorageCacheService.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName
    @State private var showAISettings = false
    @State private var showAIConsent = false
    @State private var showVoiceRecognitionSettings = false
    @State private var showHoloOneSettings = false
    @State private var showPrivacyPolicy = false
    @State private var showTermsOfUse = false
    @State private var showProfileEditor = false
    @State private var showHealthKitDiagnostics = false
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheAlert = false
    @State private var showDeleteAccountDataConfirmation = false
    @State private var isDeletingAccountData = false
    @State private var accountDataDeletionMessage: String?

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 用户信息卡片
                    userInfoCard

                    // 深色模式设置
                    darkModeSection

                    // iCloud 同步
                    iCloudSyncSection

                    // AI 整理设置
                    aiOrganizationSection

                    // AI 回放设置
                    aiPlaybackSection

                    // AI 记忆设置
                    aiMemorySection

                    // 存储与缓存
                    storageSection

                    // 法律与隐私
                    legalSection

                    // 账号与数据
                    accountDataSection

                    // 其他设置（占位）
                    otherSettingsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
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

                ToolbarItem(placement: .principal) {
                    Text("设置")
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .preferredColorScheme(darkModeManager.colorScheme)
        .id(darkModeManager.currentSetting)
        .swipeBackToDismiss { dismiss() }
        .task {
            await authService.refreshCredentialState()
            await iCloudSyncStatus.refreshAccountStatus()
            await storageService.calculateCacheSize()
        }
        .alert("退出 Apple 登录？", isPresented: $showSignOutConfirmation) {
            Button("退出登录", role: .destructive) {
                authService.signOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出登录只会清除 Holo 的本地登录状态，不会删除本机数据，也不会删除 iCloud 云端数据。")
        }
        .alert("删除 Holo 账号与数据？", isPresented: $showDeleteAccountDataConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await deleteAccountAndData() }
            }
        } message: {
            Text("这会删除本机 Holo 数据、附件、AI 记忆、缓存和登录状态。已同步到 iCloud 的 Holo 数据会在系统同步后尝试删除；如果设备离线，删除同步可能延后。")
        }
    }

    // MARK: - 用户信息卡片

    private var userInfoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    Circle()
                        .fill(authService.isSignedIn ? Color.holoPrimary.opacity(0.1) : Color.holoTextSecondary.opacity(0.1))
                        .frame(width: 56, height: 56)

                    Image(systemName: authService.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(authService.isSignedIn ? .holoPrimary : .holoTextSecondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(authService.session?.displayName ?? userName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(accountStatusSubtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if let errorMessage = authService.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if authService.isSignedIn {
                Button {
                    showSignOutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("退出登录")
                    }
                    .font(.holoBody)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                SignInWithAppleButton(.signIn) { request in
                    authService.configureSignInRequest(request)
                } onCompletion: { result in
                    authService.handleSignInCompletion(result)
                    Task {
                        await iCloudSyncStatus.refreshAccountStatus()
                    }
                }
                .signInWithAppleButtonStyle(darkModeManager.colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var accountStatusSubtitle: String {
        if authService.isSignedIn {
            if iCloudSyncStatus.accountStatus == .available {
                return "已登录，iCloud 云同步已开启"
            }
            return "已登录，本机数据会保存；登录 iCloud 后将自动同步"
        }

        if authService.status == .credentialRevoked {
            return "Apple 登录已失效，请重新登录"
        }

        return "本机模式，登录后会检查 iCloud 云同步状态"
    }

    // MARK: - 深色模式设置

    private var darkModeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "moon.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("外观")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // 深色模式选项
            VStack(spacing: 0) {
                ForEach(DarkModeSetting.allCases, id: \.self) { setting in
                    darkModeOptionRow(setting)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 深色模式选项行
    private func darkModeOptionRow(_ setting: DarkModeSetting) -> some View {
        Button {
            darkModeManager.updateSetting(setting)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(setting == darkModeManager.currentSetting
                              ? Color.holoPrimary.opacity(0.1)
                              : Color.holoBackground)
                        .frame(width: 40, height: 40)

                    Image(systemName: setting.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(setting == darkModeManager.currentSetting
                                         ? .holoPrimary
                                         : .holoTextSecondary)
                }

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    // 跟随系统时显示当前系统状态
                    if setting == .system {
                        Text(systemColorScheme == .dark ? "当前：深色" : "当前：浅色")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                Spacer()

                // 选中指示器
                if setting == darkModeManager.currentSetting {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - iCloud 同步

    @State private var iCloudRefreshToast: String?

    private var iCloudSyncSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("iCloud 同步")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 0) {
                // 账号状态
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "person.icloud")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("账号状态")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text(iCloudAccountSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 12)

                Divider()
                    .padding(.leading, 56)

                // 同步状态
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(iCloudSyncStatus.isSyncing ? Color.blue.opacity(0.1) : Color.holoPrimary.opacity(0.1))
                            .frame(width: 40, height: 40)

                        if iCloudSyncStatus.isSyncing {
                            ProgressView()
                                .tint(.blue)
                        } else {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.holoPrimary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步状态")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text(iCloudSyncStatus.lastEventDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)

                        Text(iCloudSyncStatus.syncStatusDetailText)
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.75))
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 12)

                // 错误信息
                if iCloudSyncStatus.lastErrorMessage != nil {
                    Divider()
                        .padding(.leading, 56)

                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.red.opacity(0.1))
                                .frame(width: 40, height: 40)

                            Image(systemName: "exclamationmark.icloud")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.red)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("最近错误")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Text(iCloudSyncStatus.lastErrorMessage ?? "")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                }

                Divider()
                    .padding(.leading, 56)

                // 重新检查按钮
                Button {
                    guard !iCloudSyncStatus.isRefreshing else { return }
                    iCloudRefreshToast = nil
                    Task {
                        await iCloudSyncStatus.requestManualSync()
                        iCloudRefreshToast = iCloudSyncStatus.refreshToast
                        // 2 秒后隐藏 toast
                        try? await Task.sleep(for: .seconds(2))
                        iCloudRefreshToast = nil
                    }
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.holoInfo.opacity(0.1))
                                .frame(width: 40, height: 40)

                            if iCloudSyncStatus.isRefreshing {
                                ProgressView()
                                    .tint(.holoInfo)
                            } else {
                                Image(systemName: "arrow.clockwise.icloud")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoInfo)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(iCloudSyncStatus.isRefreshing ? "正在请求同步…" : "请求同步并检查状态")
                                .font(.holoBody)
                                .foregroundColor(.holoInfo)

                            if let toast = iCloudRefreshToast {
                                Text(toast)
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoSuccess)
                                    .transition(.opacity)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    private var iCloudAccountSubtitle: String {
        guard authService.isSignedIn else {
            return "登录 Holo 后检查云同步状态"
        }

        if iCloudSyncStatus.accountStatus == .available {
            return "iCloud 可用，云同步已开启"
        }

        return iCloudSyncStatus.accountStatusText
    }

    // MARK: - AI 整理设置

    @State private var isThoughtAutoOrganizationEnabled: Bool = {
        UserDefaults.standard.object(forKey: ThoughtRepository.autoOrganizationEnabledKey) as? Bool ?? true
    }()

    private var aiOrganizationSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "tag.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("AI 整理")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // 自动整理想法开关
            settingsRow(
                icon: "hand.raised.square",
                iconColor: .holoPrimary,
                title: "HoloAI 数据授权",
                subtitle: HoloAIFeatureFlags.aiDataProcessingConsentGranted ? "已授权，可随时撤回" : "未授权，AI 功能暂停"
            ) {
                showAIConsent = true
            }
            .sheet(isPresented: $showAIConsent) {
                NavigationStack {
                    AIDataProcessingConsentView()
                }
            }

            // 自动整理想法开关
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动整理想法")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(isThoughtAutoOrganizationEnabled
                         ? "保存想法后，AI 会自动生成标签和主题，可随时编辑"
                         : "已关闭，手动标签和正文 #标签 仍会保留")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: $isThoughtAutoOrganizationEnabled)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: isThoughtAutoOrganizationEnabled) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: ThoughtRepository.autoOrganizationEnabledKey)
        }
    }

    // MARK: - AI 回放设置

    private var aiPlaybackSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("AI 回放")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // 开关列表
            VStack(spacing: 0) {
                // 每周提醒
                insightToggleRow(
                    icon: "calendar.badge.clock",
                    iconColor: .holoPrimary,
                    title: "每周提醒我生成周回放",
                    subtitle: weeklyReminderSubtitle,
                    isOn: $insightSettings.weeklyReminderEnabled
                )

                Divider()
                    .padding(.leading, 56)

                // 每月提醒
                insightToggleRow(
                    icon: "calendar.circle",
                    iconColor: .holoSuccess,
                    title: "每月提醒我生成月回放",
                    subtitle: monthlyReminderSubtitle,
                    isOn: $insightSettings.monthlyReminderEnabled
                )

                Divider()
                    .padding(.leading, 56)

                // 后台自动生成
                insightToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: .holoInfo,
                    title: "允许后台自动尝试生成",
                    subtitle: "iOS 不保证准时执行，下次打开 App 时会补生成",
                    isOn: $insightSettings.backgroundAutoGenerationEnabled
                )
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 周提醒描述
    private var weeklyReminderSubtitle: String {
        if insightSettings.weeklyReminderEnabled {
            return "每\(insightSettings.weeklyReminderWeekdayName) \(String(format: "%02d", insightSettings.weeklyReminderHour)):00"
        }
        return "默认关闭"
    }

    /// 月提醒描述
    private var monthlyReminderSubtitle: String {
        if insightSettings.monthlyReminderEnabled {
            return "每月\(insightSettings.monthlyReminderDay)日 \(String(format: "%02d", insightSettings.monthlyReminderHour)):00"
        }
        return "默认关闭"
    }

    /// AI 回放 Toggle 行
    private func insightToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }

    // MARK: - AI 记忆设置

    @State private var showMemoryCenter = false

    private var aiMemorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("AI 记忆")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 0) {
                insightToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: .holoPrimary,
                    title: "长期记忆",
                    subtitle: memorySettings.longTermMemoryEnabled ? "AI 会从洞察中学习偏好与模式" : "默认关闭",
                    isOn: $memorySettings.longTermMemoryEnabled
                )

                Divider()
                    .padding(.leading, 56)

                insightToggleRow(
                    icon: "text.bubble",
                    iconColor: .holoInfo,
                    title: "记忆辅助对话",
                    subtitle: memorySettings.memorySummaryInjectionEnabled ? "对话中利用已记住的信息辅助回答" : "默认开启",
                    isOn: $memorySettings.memorySummaryInjectionEnabled
                )

                Divider()
                    .padding(.leading, 56)

                settingsRow(
                    icon: "list.bullet.rectangle",
                    iconColor: .holoPrimary,
                    title: "记忆管理",
                    subtitle: {
                        let confirmed = HoloLongTermMemoryStore.queryConfirmed().count
                        let candidates = HoloLongTermMemoryStore.queryCandidates().count
                        if confirmed == 0 && candidates == 0 {
                            return "暂无记忆"
                        }
                        var parts: [String] = []
                        if confirmed > 0 { parts.append("\(confirmed) 条已记住") }
                        if candidates > 0 { parts.append("\(candidates) 条待确认") }
                        return parts.joined(separator: "，")
                    }()
                ) {
                    showMemoryCenter = true
                }
                .sheet(isPresented: $showMemoryCenter) {
                    NavigationStack {
                        HoloMemoryCenterView()
                    }
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    // MARK: - 其他设置（占位）

    private var otherSettingsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "gearshape.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoTextSecondary)

                Text("通用")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // Holo One 设置
            settingsRow(
                icon: "star.circle",
                iconColor: .holoPrimary,
                title: "Holo One",
                subtitle: "配置中心按钮快捷动作"
            ) {
                showHoloOneSettings = true
            }
            .sheet(isPresented: $showHoloOneSettings) {
                NavigationStack {
                    HoloOneSettingsView()
                }
            }

            // 个人档案
            settingsRow(
                icon: "person.text.rectangle",
                iconColor: .holoPrimary,
                title: "个人档案",
                subtitle: HoloProfileService.shared.hasProfile ? "已配置" : "未配置"
            ) {
                showProfileEditor = true
            }
            .sheet(isPresented: $showProfileEditor) {
                NavigationStack {
                    HoloProfileEditorView()
                }
            }

            #if DEBUG
            // AI 设置（仅开发调试）
            settingsRow(
                icon: "sparkles",
                iconColor: .purple,
                title: "AI 助手",
                subtitle: "开发调试：Provider、Prompt 与学习映射"
            ) {
                showAISettings = true
            }
            .sheet(isPresented: $showAISettings) {
                NavigationStack {
                    AISettingsView()
                }
            }

            settingsRow(
                icon: "waveform.circle",
                iconColor: .holoInfo,
                title: "语音识别",
                subtitle: KeychainService.hasCachedVoiceRecognitionConfig ? "已配置" : "开发调试：阿里云百炼 Qwen-ASR"
            ) {
                showVoiceRecognitionSettings = true
            }
            .sheet(isPresented: $showVoiceRecognitionSettings) {
                NavigationStack {
                    VoiceRecognitionSettingsView()
                }
            }
            #endif

            // 关于
            settingsRow(
                icon: "info.circle",
                iconColor: .holoInfo,
                title: "关于 Holo",
                subtitle: appVersionText
            ) {
                // TODO: 显示关于页面
            }

            diagnosticsSection
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "版本 \(version) (\(build))"
    }

    // MARK: - 存储与缓存

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("存储与缓存")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 0) {
                // 缓存大小
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.holoInfo.opacity(0.1))
                            .frame(width: 40, height: 40)

                        if storageService.isCalculating {
                            ProgressView()
                                .tint(.holoInfo)
                        } else {
                            Image(systemName: "chart.bar")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.holoInfo)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("缓存大小")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text(storageService.formattedSize)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 12)

                Divider()
                    .padding(.leading, 56)

                // 清除缓存按钮
                Button {
                    showClearCacheAlert = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(storageService.isClearing || storageService.cacheSize == 0
                                      ? Color.holoTextSecondary.opacity(0.1)
                                      : Color.red.opacity(0.1))
                                .frame(width: 40, height: 40)

                            if storageService.isClearing {
                                ProgressView()
                                    .tint(.red)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(storageService.cacheSize == 0 ? .holoTextSecondary : .red)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("清除缓存")
                                .font(.holoBody)
                                .foregroundColor(storageService.cacheSize == 0 ? .holoTextSecondary : .red)

                            Text("清理诊断日志和过期数据，不会删除你的数据")
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(storageService.isClearing || storageService.cacheSize == 0)
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
        .alert("确认清除缓存？", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { await storageService.clearCache() }
            }
        } message: {
            Text("将清理 AI 诊断日志和过期数据，你的对话、记忆和其他数据不会受影响。")
        }
    }

    // MARK: - 法律与隐私

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("法律与隐私")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            settingsRow(
                icon: "shield.checkered",
                iconColor: .holoPrimary,
                title: "隐私政策",
                subtitle: "了解我们如何保护你的数据"
            ) {
                showPrivacyPolicy = true
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                LegalDocumentSheet(documentType: .privacyPolicy)
            }

            settingsRow(
                icon: "doc.text",
                iconColor: .holoInfo,
                title: "用户协议",
                subtitle: "服务条款与使用规范"
            ) {
                showTermsOfUse = true
            }
            .sheet(isPresented: $showTermsOfUse) {
                LegalDocumentSheet(documentType: .termsOfUse)
            }
        }
    }

    // MARK: - 账号与数据

    private var accountDataSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "person.crop.circle.badge.minus")
                    .font(.system(size: 18))
                    .foregroundColor(.red)

                Text("账号与数据")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(spacing: 0) {
                Button {
                    showDeleteAccountDataConfirmation = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isDeletingAccountData ? Color.holoTextSecondary.opacity(0.1) : Color.red.opacity(0.1))
                                .frame(width: 40, height: 40)

                            if isDeletingAccountData {
                                ProgressView()
                                    .tint(.red)
                            } else {
                                Image(systemName: "trash.slash")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.red)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除账号与 Holo 数据")
                                .font(.holoBody)
                                .foregroundColor(.red)

                            Text("清除本机数据、附件、AI 记忆和登录状态")
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)

                            if let accountDataDeletionMessage {
                                Text(accountDataDeletionMessage)
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer()
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isDeletingAccountData)
            }
        }
    }

    private func deleteAccountAndData() async {
        guard !isDeletingAccountData else { return }
        isDeletingAccountData = true
        accountDataDeletionMessage = nil
        defer { isDeletingAccountData = false }

        do {
            // 1. 清除本地数据（Core Data → iCloud 同步删除、文件、Keychain、UserDefaults）
            let result = try await AccountDataDeletionService.shared.deleteAccountAndLocalData()
            // 2. 清除内存中的登录态
            authService.markAccountDeleted()
            accountDataDeletionMessage = "已删除 \(result.deletedObjectCount) 条本机记录；iCloud 删除同步由系统继续处理。"
            await storageService.calculateCacheSize()
        } catch {
            accountDataDeletionMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 诊断与数据管理

    @State private var showClearThoughtDataAlert: Bool = false

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)

                Text("数据管理")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            #if DEBUG
            // HealthKit 诊断页是开发自测工具（生成 raw 报告 + 复制），普通用户无价值，Release 不暴露
            settingsRow(
                icon: "heart.text.square",
                iconColor: .holoInfo,
                title: "健康数据诊断",
                subtitle: "HealthKit 来源与类型汇总"
            ) {
                showHealthKitDiagnostics = true
            }
            .sheet(isPresented: $showHealthKitDiagnostics) {
                NavigationStack {
                    HealthKitDiagnosticsView()
                }
            }
            #endif

            Button {
                showClearThoughtDataAlert = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "trash.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("清除观点数据")
                            .font(.holoBody)
                            .foregroundColor(.red)

                        Text("删除所有观点、标签和引用")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())
            .alert("确认清除观点数据？", isPresented: $showClearThoughtDataAlert) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    clearThoughtData()
                }
            } message: {
                Text("此操作将删除所有观点、标签和引用数据，不可恢复。")
            }
        }
    }

    private func clearThoughtData() {
        do {
            let repo = ThoughtRepository()
            try repo.deleteAllThoughtData()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            Logger(subsystem: "com.holo.app", category: "Settings").error("清除观点数据失败: \(error.localizedDescription)")
        }
    }

    /// 通用设置行
    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.1))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(iconColor)
                }

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
