//
//  SettingsView.swift
//  Holo
//
//  设置页面 - 2026-10-25 规整（原型契约：docs/_common/plans/2026-10-25-设置页规整/）：
//  11 个分组收敛为 5 组 + 底部孤立危险区——AI 与记忆 / 数据与同步 / 隐私与安全 / 通用。
//  低频项收进二级页（外观三选一、AI 回放开关、iCloud、日历），
//  政策文档与「重看引导/笔记」归入关于页，缓存管理归入数据管理页。
//  宽屏（expanded 档）双栏：左侧分组导航（含用户信息卡 + 底部危险区入口），右侧渲染所选分组；
//  窄屏/iPhone 单列长滚动。
//

import SwiftUI
import CloudKit
import OSLog
import AuthenticationServices

// MARK: - SettingsView

/// 设置页面
struct SettingsView: View {

    /// 设置分组：与单列滚动的 section 一一对应，双栏左列的导航项。
    /// danger 不进常规导航——单列时孤立页面底部，双栏时左列底部固定红行（iOS 危险操作惯例）。
    /// v3.1：原「AI 与记忆」组整删——数据授权/想法整理/周期回放开关在 HoloAI 聚合页里
    /// 全都有（回放那边 4 个开关更全），一级行是重复入口；HoloAI 降为用户卡下的独立入口卡。
    private enum SettingsSection: String, Identifiable {
        case dataSync, privacySecurity, general, danger

        var id: String { rawValue }

        /// 双栏左列常规导航项（不含 danger）
        static let navCases: [SettingsSection] = [.dataSync, .privacySecurity, .general]

        var title: String {
            switch self {
            case .dataSync: return String(localized: "数据与同步")
            case .privacySecurity: return String(localized: "隐私与安全")
            case .general: return String(localized: "通用")
            case .danger: return String(localized: "删除账号与数据")
            }
        }

        var icon: String {
            switch self {
            case .dataSync: return "internaldrive.fill"
            case .privacySecurity: return "lock.shield.fill"
            case .general: return "gearshape"
            case .danger: return "trash"
            }
        }
    }

    // MARK: - Environment

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var systemColorScheme

    /// 自定义关闭动作（iPad v2 页面层传入：关层并把侧边栏切回「今天」）。
    /// 未传入（sheet 场景）时走系统 dismiss。
    var onClose: (() -> Void)? = nil

    /// 统一关闭入口
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    // MARK: - Observed Objects

    @ObservedObject private var darkModeManager = DarkModeManager.shared
    @ObservedObject private var iCloudSyncStatus = ICloudSyncStatusService.shared
    @ObservedObject private var authService = AppleSignInAuthService.shared
    @ObservedObject private var appLockSettings = AppLockSettings.shared
    @ObservedObject private var appLockManager = AppLockManager.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName
    /// 任务纸面动效灰度开关（动效融合 G2）：key/默认值与 HoloTaskMotionRolloutPolicy 对齐，
    /// 未设置时默认开；拨动即落 UserDefaults，重启/即时生效（外观由视图每次取值）
    @AppStorage(HoloTaskMotionRolloutPolicy.Flag.taskPaperMotionEnabled.rawValue) private var taskPaperMotionEnabled: Bool = true
    #if DEBUG
    /// 「开发者选项」折叠行展开状态（默认收起，跨启动记忆）
    @AppStorage("settings.developerOptionsExpanded") private var developerOptionsExpanded = false
    #endif
    @State private var showAISettings = false
    @State private var showMatterV2Prototype = false
    @State private var showVoiceRecognitionSettings = false
    @State private var showHealthKitDiagnostics = false
    @State private var showSignOutConfirmation = false
    @State private var showDeleteAccountDataConfirmation = false
    @State private var isDeletingAccountData = false
    @State private var accountDataDeletionMessage: String?
    @State private var showAbout = false
    @State private var showFeedback = false
    @State private var showAppLockUnavailableAlert = false
    @State private var appLockUnavailableMessage: String?
    /// 开启验证（弹系统验证框）期间用户是否仍意图开启；防止验证回调晚到时覆盖用户已拨回的开关
    @State private var appLockEnablePending = false
    @State private var showUserProfileEditor = false

    // 规整后新增的二级页
    @State private var showAppearancePage = false
    @State private var showICloudSyncPage = false
    @State private var showCalendarPage = false

    @State private var showNotificationSettings = false
    @State private var showHoloAIUserSettings = false
    @State private var showDataManagement: Bool = false

    // 宽屏双栏：当前选中的分组
    @State private var selectedSection: SettingsSection = .dataSync
    @Environment(\.holoContentWidth) private var settingsWindowWidth
    private var isWideLayout: Bool { HoloAdaptiveLayout.isExpandedWidth(settingsWindowWidth) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            settingsContent
                .background(Color.holoToolBackground)
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

                    ToolbarItem(placement: .principal) {
                        Text("设置")
                            .holoText(.sectionTitle)
                            .foregroundColor(.holoToolText)
                    }
                }
        }
        .preferredColorScheme(darkModeManager.colorScheme)
        .id(darkModeManager.currentSetting)
        .swipeBackToDismiss { close() }
        .task {
            await authService.refreshCredentialState()
            await iCloudSyncStatus.refreshAccountStatus()
        }
        .alert("退出 Apple 登录？", isPresented: $showSignOutConfirmation) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                authService.signOut()
            }
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
        .sheet(isPresented: $showUserProfileEditor) {
            UserProfileEditorView()
        }
    }

    // MARK: - 双栏外壳（expanded）/ 单列长滚动（medium 与 iPhone）

    @ViewBuilder
    private var settingsContent: some View {
        if isWideLayout {
            HStack(spacing: 0) {
                settingsNavColumn
                Rectangle()
                    .fill(Color.holoToolBorder.opacity(0.4))
                    .frame(width: 0.5)
                selectedSectionPane
            }
        } else {
            settingsScroll
        }
    }

    /// 单列长滚动（窄屏/iPhone）：用户卡 + HoloAI 总入口 + 三组 + 底部孤立危险区
    private var settingsScroll: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                userInfoCard
                holAICard
                dataSyncSection
                privacySecuritySection
                generalSection
                dangerSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    /// 宽屏左列：用户信息卡 + HoloAI 总入口 + 分组导航 + 底部危险区入口
    private var settingsNavColumn: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    userInfoCard

                    holAICard

                    VStack(spacing: 4) {
                        ForEach(SettingsSection.navCases) { section in
                            settingsNavRow(section)
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.md)
            }

            Spacer(minLength: 0)

            // 危险区固定左列底部：与单列「孤立最底」同语义
            dangerNavRow
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.md)
        }
        .frame(width: 252)
    }

    private func settingsNavRow(_ section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            guard selectedSection != section else { return }
            withAnimation(HoloAnimation.quick) {
                selectedSection = section
            }
            HapticManager.light()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .holoPrimary : .holoToolTextSecondary)
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 宽屏左列底部危险区行：红字，选中态与常规导航一致但用红系
    private var dangerNavRow: some View {
        let isSelected = selectedSection == .danger
        return Button {
            guard selectedSection != .danger else { return }
            withAnimation(HoloAnimation.quick) {
                selectedSection = .danger
            }
            HapticManager.light()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: SettingsSection.danger.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .holoToolError : .holoToolTextSecondary)
                    .frame(width: 22)
                Text(SettingsSection.danger.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .holoToolError : .holoToolTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(isSelected ? Color.holoError.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 宽屏右栏：只渲染所选分组（id 重置滚动，切组从顶部开始读）
    private var selectedSectionPane: some View {
        ScrollView(showsIndicators: false) {
            sectionBody(selectedSection)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selectedSection)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sectionBody(_ section: SettingsSection) -> some View {
        switch section {
        case .dataSync: dataSyncSection
        case .privacySecurity: privacySecuritySection
        case .general: generalSection
        case .danger: dangerSection
        }
    }

    // MARK: - 分组标题

    private func sectionHeader(icon: String, title: String, color: Color = .holoPrimary) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)

            Text(title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)
        }
    }

    // MARK: - 用户信息卡片

    /// 全设置页唯一的头像：头像 + 昵称 + 账号状态一行可点进「个人资料」编辑器，
    /// 卡片下方仍是登录/退出（原「个人资料」卡片与其合并，不再出现第二个头像）
    private var userInfoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Button {
                showUserProfileEditor = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    UserAvatarView(size: 56, showsSignedInBadge: authService.isSignedIn)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(authService.session?.displayName ?? UserDisplayNameSettings.displayOrPlaceholder(userName))
                            .holoText(.body)
                            .foregroundColor(.holoToolText)

                        Text(accountStatusSubtitle)
                            .holoText(.supporting)
                            .foregroundColor(.holoToolTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if let errorMessage = authService.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolError)
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
                    .holoText(.body)
                    .foregroundColor(.holoToolError)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.holoError.opacity(0.08))
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
                // 跟随系统时 colorScheme 为 nil，旧写法会在系统深色下仍渲染纯黑按钮；
                // 用环境 scheme 兜底，按钮样式与实际界面明暗保持一致
                .signInWithAppleButtonStyle((darkModeManager.colorScheme ?? systemColorScheme) == .dark ? .white : .black)
                .frame(height: 44)
                // 通宵冲刺 D6（东林拍板项）：Apple 登录按钮在 iPad（regular）限宽居中；
                // iPhone 维持拉满全宽不变
                .modifier(AppleButtonWidthCapModifier())
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var accountStatusSubtitle: String {
        if authService.isSignedIn {
            if iCloudSyncStatus.accountStatus == .available {
                return String(localized: "已登录，iCloud 云同步已开启")
            }
            return String(localized: "已登录，本机数据会保存；登录 iCloud 后将自动同步")
        }

        if authService.status == .credentialRevoked {
            return String(localized: "Apple 登录已失效，请重新登录")
        }

        return String(localized: "本机模式，登录后会检查 iCloud 云同步状态")
    }

    // MARK: - HoloAI 总入口（独立卡）

    /// AI 设置唯一总入口：一个发现/长期记忆/自动处理（想法整理·周期回放）/数据与隐私
    /// 都在 HoloAI 聚合页内（v3.1 review：一级行曾是重复入口，整组删除收敛于此）
    private var holAICard: some View {
        SettingsNavRow(
            icon: "sparkles",
            iconColor: .holoPrimary,
            title: String(localized: "HoloAI"),
            subtitle: String(localized: "一个发现 · 记忆 · 自动处理 · 数据与隐私")
        ) {
            showHoloAIUserSettings = true
        }
        .sheet(isPresented: $showHoloAIUserSettings) {
            HoloAIUserSettingsView(discoveryService: DiscoveryCoordinator.shared)
        }
    }

    // MARK: - 数据与同步

    /// iCloud 同步 + 日历 + 数据管理（原 iCloud/日历/存储缓存/通用内数据管理四处归一；
    /// 缓存大小与清除缓存收进数据管理页）
    private var dataSyncSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "internaldrive", title: "数据与同步")

            VStack(spacing: 0) {
                SettingsNavRow(
                    icon: "icloud.fill",
                    iconColor: .holoInfo,
                    title: String(localized: "iCloud 同步"),
                    subtitle: iCloudRowSubtitle
                ) {
                    showICloudSyncPage = true
                }
                .sheet(isPresented: $showICloudSyncPage) {
                    SettingsSheetShell(String(localized: "iCloud 同步")) {
                        SettingsICloudSyncSection(showsSectionHeader: false)
                    }
                }

                Divider().padding(.leading, 56)

                SettingsNavRow(
                    icon: "calendar",
                    iconColor: .holoInfo,
                    title: String(localized: "日历")
                ) {
                    showCalendarPage = true
                }
                .sheet(isPresented: $showCalendarPage) {
                    SettingsSheetShell(String(localized: "日历")) {
                        ScheduleSettingsSection(showsSectionHeader: false)
                    }
                }

                Divider().padding(.leading, 56)

                // 数据管理（模块清空/清空所有数据/最近删除回收站/缓存管理统一入口）
                SettingsNavRow(
                    icon: "externaldrive.badge.timemachine",
                    iconColor: .holoInfo,
                    title: String(localized: "数据管理"),
                    subtitle: String(localized: "最近删除 · 清空 · 缓存")
                ) {
                    showDataManagement = true
                }
                .sheet(isPresented: $showDataManagement) {
                    DataManagementView()
                }
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// iCloud 入口行副标题：与 iCloud 同步二级页的「账号状态」同源口径
    private var iCloudRowSubtitle: String {
        guard authService.isSignedIn else {
            return String(localized: "登录 Holo 后检查云同步状态")
        }
        if iCloudSyncStatus.accountStatus == .available {
            return String(localized: "iCloud 可用，云同步已开启")
        }
        return iCloudSyncStatus.accountStatusText
    }

    // MARK: - 隐私与安全

    /// 应用锁 + 从属的锁定时机 + 小组件隐私（v3.1：政策文档移入关于页；图标整组绿色；
    /// 锁定时机为应用锁开启时出现的缩进从属行）
    private var privacySecuritySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "lock.shield.fill", title: "隐私与安全")

            VStack(spacing: 0) {
                SettingsToggleRow(
                    icon: "faceid",
                    iconColor: .holoSuccess,
                    title: String(localized: "应用锁"),
                    isOn: appLockBinding
                )

                if appLockSettings.isEnabled {
                    Divider().padding(.leading, 56)

                    appLockGraceRow
                }

                Divider().padding(.leading, 56)

                SettingsToggleRow(
                    icon: "widget",
                    iconColor: .holoSuccess,
                    title: String(localized: "小组件显示想法原文"),
                    subtitle: String(localized: "关闭后桌面只显示来源提示"),
                    isOn: thoughtExcerptBinding
                )
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
        .alert("无法开启应用锁", isPresented: $showAppLockUnavailableAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(appLockUnavailableMessage ?? "")
        }
    }

    /// 切换后立即重写想法快照并刷新小组件；当日选取是确定性的，内容不会跳变
    private var thoughtExcerptBinding: Binding<Bool> {
        Binding(
            get: { HoloWidgetPrivacySettings.showsThoughtExcerpt },
            set: { visible in
                HoloWidgetPrivacySettings.setShowsThoughtExcerpt(visible)
                Task { @MainActor in
                    HoloWidgetSnapshotService.shared.refreshThoughtMemorySnapshot()
                }
            }
        )
    }

    /// 开启前先预检设备、再现场验证一次，成功才落开关；取消验证则弹回
    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { appLockSettings.isEnabled },
            set: { wantsOn in
                appLockEnablePending = wantsOn
                guard wantsOn else {
                    appLockSettings.isEnabled = false
                    return
                }
                switch appLockManager.deviceLockReadiness() {
                case .unavailable(let message):
                    appLockEnablePending = false
                    appLockUnavailableMessage = message
                    showAppLockUnavailableAlert = true
                case .ready:
                    Task { @MainActor in
                        let confirmed = await appLockManager.validateForEnabling()
                        // 验证期间用户可能已把开关拨回，只在意图仍是「开」时落开关
                        if confirmed, appLockEnablePending {
                            appLockSettings.isEnabled = true
                        }
                        appLockEnablePending = false
                    }
                }
            }
        )
    }

    /// 锁定时机三档（立即 / 1 分钟 / 5 分钟，默认 5 分钟）。
    /// v3.1：应用锁的从属设置——缩进小行样式（小图标砖 + 次级文字），仅应用锁开启时出现
    private var appLockGraceRow: some View {
        Menu {
            ForEach(AppLockSettings.GraceStyle.allCases, id: \.self) { style in
                Button {
                    appLockSettings.graceStyle = style
                } label: {
                    if style == appLockSettings.graceStyle {
                        Label(style.displayName, systemImage: "checkmark")
                    } else {
                        Text(style.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(Color.holoSuccess.opacity(0.1))
                        .frame(width: 28, height: 28)

                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoSuccess)
                }

                Text("锁定时机")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(appLockSettings.graceStyle.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .padding(.leading, 42)
            .padding(.trailing, HoloSpacing.md)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }

    // MARK: - 通用

    /// 外观（入口行）+ 通知 + 反馈 + 关于（政策文档与重看引导收进关于页）
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "gearshape.circle.fill", title: "通用", color: .holoToolTextSecondary)

            VStack(spacing: 0) {
                // 外观：一级只留一行，右侧显示当前值，点开三选一
                SettingsNavRow(
                    icon: "moon.circle.fill",
                    iconColor: .holoToolTextSecondary,
                    title: String(localized: "外观"),
                    value: darkModeManager.currentSetting.displayName
                ) {
                    showAppearancePage = true
                }
                .sheet(isPresented: $showAppearancePage) {
                    SettingsAppearancePage()
                }

                Divider().padding(.leading, 56)

                // 统一通知中心入口（早报/习惯提醒/晨报/AI 回放的完整开关与时间都在这里）
                SettingsNavRow(
                    icon: "bell.badge",
                    iconColor: .holoToolTextSecondary,
                    title: String(localized: "通知")
                ) {
                    showNotificationSettings = true
                }
                .sheet(isPresented: $showNotificationSettings) {
                    NotificationSettingsView()
                }

                Divider().padding(.leading, 56)

                SettingsNavRow(
                    icon: "ellipsis.bubble",
                    iconColor: .holoToolTextSecondary,
                    title: String(localized: "反馈")
                ) {
                    showFeedback = true
                }
                .sheet(isPresented: $showFeedback) {
                    FeedbackSheet()
                }

                Divider().padding(.leading, 56)

                // 关于：版本 + 政策文档 + 重看引导（二级聚合页）
                SettingsNavRow(
                    icon: "info.circle",
                    iconColor: .holoToolTextSecondary,
                    title: String(localized: "关于 Holo"),
                    subtitle: appVersionText
                ) {
                    showAbout = true
                }
                .sheet(isPresented: $showAbout) {
                    NavigationStack {
                        AboutView(
                            onReplayCoachTour: {
                                // 先关设置页再等动画收尾，然后触发首页导览重播
                                close()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    NotificationCenter.default.post(name: .replayHomeCoachTour, object: nil)
                                }
                            },
                            onReplayWelcomeNote: {
                                close()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    DeepLinkState.shared.navigate(to: .thoughtDetail(thoughtId: WelcomeNoteSeed.noteId))
                                }
                            }
                        )
                    }
                }
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

            #if DEBUG
            developerOptionsSection
            #endif
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return String(localized: "版本 \(version) (\(build))")
    }

    #if DEBUG
    /// 开发者选项：四个开发调试入口收进折叠行，默认收起，展开状态跨启动记忆
    @ViewBuilder
    private var developerOptionsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    developerOptionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    SettingsIconTile(icon: "wrench.and.screwdriver", iconColor: .holoPrimary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "开发者选项"))
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)

                        Text(String(localized: "动效、模型与语音调试入口"))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                        .rotationEffect(.degrees(developerOptionsExpanded ? 90 : 0))
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())

            if developerOptionsExpanded {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    // 任务纸面动效（灰度回退开关）：动效融合 G2——
                    // 关闭即恢复任务模块原布局（大数字仪表/白卡/白底横幅），不动数据
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 18))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("任务纸面动效")
                                .holoText(.body)
                                .foregroundColor(.holoToolText)
                            Text(String(localized: "任务模块纸页视觉"))
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoToolTextSecondary)
                        }

                        Spacer(minLength: 8)

                        Toggle("", isOn: $taskPaperMotionEnabled)
                            .labelsHidden()
                            .tint(.holoPrimary)
                    }
                    .padding(.vertical, 6)

                    // AI 设置：仅 Debug 构建可见（服务商/API Key/温度/Token 是开发者参数；
                    // 2026-10-21 拍板退役入口，代码保留，预留未来 Pro 版自接 API）
                    settingsRow(
                        icon: "sparkles",
                        iconColor: .purple,
                        title: String(localized: "AI 助手"),
                        subtitle: String(localized: "模型与提示词配置")
                    ) {
                        showAISettings = true
                    }
                    .sheet(isPresented: $showAISettings) {
                        NavigationStack {
                            AISettingsView()
                        }
                    }

                    // Matter V2 静态样机：新规划卡/详情/Today 与旧卡对照
                    settingsRow(
                        icon: "square.stack.3d.up",
                        iconColor: .holoPrimary,
                        title: "Matter V2 样机",
                        subtitle: String(localized: "新规划卡样机")
                    ) {
                        showMatterV2Prototype = true
                    }
                    .sheet(isPresented: $showMatterV2Prototype) {
                        NavigationStack {
                            MatterV2PrototypeView()
                        }
                    }

                    settingsRow(
                        icon: "waveform.circle",
                        iconColor: .holoInfo,
                        title: String(localized: "语音识别"),
                        subtitle: KeychainService.hasCachedVoiceRecognitionConfig ? String(localized: "已配置") : String(localized: "语音识别引擎")
                    ) {
                        showVoiceRecognitionSettings = true
                    }
                    .sheet(isPresented: $showVoiceRecognitionSettings) {
                        NavigationStack {
                            VoiceRecognitionSettingsView()
                        }
                    }

                    // HealthKit 诊断页是开发自测工具（生成 raw 报告 + 复制），普通用户无价值，Release 不暴露
                    settingsRow(
                        icon: "heart.text.square",
                        iconColor: .holoInfo,
                        title: String(localized: "健康数据诊断"),
                        subtitle: String(localized: "HealthKit 来源与类型汇总")
                    ) {
                        showHealthKitDiagnostics = true
                    }
                    .sheet(isPresented: $showHealthKitDiagnostics) {
                        NavigationStack {
                            HealthKitDiagnosticsView()
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - 底部危险区（孤立，无组标题）

    /// 删除账号与数据：孤立最底（原「账号与数据」组去标题；iOS 危险操作惯例）
    private var dangerSection: some View {
        VStack(spacing: 0) {
            Button {
                showDeleteAccountDataConfirmation = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isDeletingAccountData ? Color.holoToolTextSecondary.opacity(0.1) : Color.holoError.opacity(0.1))
                            .frame(width: 40, height: 40)

                        if isDeletingAccountData {
                            ProgressView()
                                .tint(.holoToolError)
                        } else {
                            Image(systemName: "trash.slash")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.holoToolError)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("删除账号与数据")
                            .holoText(.body)
                            .foregroundColor(.holoToolError)

                        if let accountDataDeletionMessage {
                            Text(accountDataDeletionMessage)
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()
                }
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isDeletingAccountData)
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
            // 2. 撤销 Apple 凭证并清除内存中的登录态
            await authService.markAccountDeleted()
            UserAvatarRepository.shared.resetPublishedStateAfterAccountDeletion()
            accountDataDeletionMessage = String(localized: "已删除 \(result.deletedObjectCount) 条本机记录；iCloud 删除同步由系统继续处理。")
        } catch {
            accountDataDeletionMessage = String(localized: "删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 开发者选项内用行（独立小卡样式，与折叠区一致）

    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        SettingsNavRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle, action: action)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}

/// Apple 登录按钮宽屏限宽（通宵冲刺 D6）：regular（iPad）下 360pt 居中，
/// compact（iPhone）直通保持全宽。
struct AppleButtonWidthCapModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            content
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
