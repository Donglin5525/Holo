//
//  SettingsView.swift
//  Holo
//
//  设置入口按用户任务分组：使用偏好 / 数据与同步 / 隐私与安全 / HoloAI 与想法 / 帮助与反馈。
//  最近删除、账单迁移、隐私授权与使用帮助直接可达；周期回放统一进入 HoloAI 设置。
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
    private enum SettingsSection: String, Identifiable {
        case general, dataSync, privacySecurity, aiMemory, support, danger

        var id: String { rawValue }

        /// 双栏左列常规导航项（不含 danger）
        static let navCases: [SettingsSection] = [.general, .dataSync, .privacySecurity, .aiMemory, .support]

        var title: String {
            switch self {
            case .aiMemory: return String(localized: "HoloAI 与想法")
            case .dataSync: return String(localized: "数据与同步")
            case .privacySecurity: return String(localized: "隐私与安全")
            case .general: return String(localized: "使用偏好")
            case .support: return String(localized: "帮助与反馈")
            case .danger: return String(localized: "删除账号与数据")
            }
        }

        var icon: String {
            switch self {
            case .aiMemory: return "sparkles"
            case .dataSync: return "internaldrive.fill"
            case .privacySecurity: return "lock.shield.fill"
            case .general: return "slider.horizontal.3"
            case .support: return "questionmark.circle"
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
    /// 从个人页打开设置时，重看引导需要一并退回首页。
    var onReturnHome: (() -> Void)? = nil

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
    @ObservedObject private var aiConsent = HoloAIDataProcessingConsent.shared
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
    @State private var showAIConsent = false
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
    @State private var showRecycleBin = false
    @State private var showFinanceTransfer = false
    @State private var showThoughtAIScope = false
    @State private var showPrivacyPolicy = false
    @State private var showHelp = false
    @State private var showMemoryLab = false
    @State private var showICloudSyncPage = false
    @State private var showCalendarPage = false

    @State private var showThoughtOrganizationSettings = false
    @State private var showNotificationSettings = false
    @State private var showHoloAIUserSettings = false
    @State private var showDataManagement: Bool = false

    // 宽屏双栏：当前选中的分组
    @State private var selectedSection: SettingsSection = .general
    @Environment(\.holoContentWidth) private var settingsWindowWidth
    private var isWideLayout: Bool { HoloAdaptiveLayout.isExpandedWidth(settingsWindowWidth) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            settingsContent
                .background(Color.holoToolBackground)
                .navigationTitle("设置")
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
                        .accessibilityLabel("关闭设置")
                    }
                }
        }
        .preferredColorScheme(darkModeManager.colorScheme)
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

    /// 单列长滚动（窄屏/iPhone）：用户卡 + 四组 + 底部孤立危险区
    private var settingsScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                userInfoCard
                generalSection
                dataSyncSection
                privacySecuritySection
                aiMemorySection
                supportSection
                #if DEBUG
                developerOptionsSection
                #endif
                dangerSection
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    /// 宽屏左列：用户信息卡 + 分组导航 + 底部危险区入口
    private var settingsNavColumn: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    userInfoCard

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
        .frame(width: 280)
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
                    .holoText(.supporting)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
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
                    .holoText(.supporting)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundColor(isSelected ? .holoToolError : .holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
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
        case .aiMemory: aiMemorySection
        case .dataSync: dataSyncSection
        case .privacySecurity: privacySecuritySection
        case .general: generalSection
        case .support: supportSection
        case .danger: dangerSection
        }
    }

    // MARK: - 分组标题

    private func sectionHeader(icon: String, title: String, color: Color = .holoPrimary) -> some View {
        Text(title)
            .holoText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
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
                        .fixedSize()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(UserDisplayNameSettings.isDisplayNameSet(userName) ? userName : String(localized: "个人资料"))
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

            if authService.errorMessage != nil {
                Text("暂时无法确认登录状态，请重试 Apple 登录")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !authService.isSignedIn {
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
        .holoSurface()
    }

    private var accountStatusSubtitle: String {
        if authService.isSignedIn {
            return String(localized: "已通过 Apple 登录 Holo")
        }

        if authService.status == .credentialRevoked {
            return String(localized: "Apple 登录已失效，请重新登录")
        }

        return String(localized: "尚未登录 Holo 账号")
    }

    // MARK: - AI 与记忆

    /// AI 行为统一进入 HoloAI 设置；授权与排除范围归入隐私组。
    private var aiMemorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "sparkles", title: "HoloAI 与想法")

            VStack(spacing: 0) {
                // HoloAI 统一用户设置（2026-10-23「一个发现」随附）：一个发现/长期记忆/自动处理/数据与隐私
                // 的聚合页；与 HoloAI 页右上角齿轮同一页面（01 §4 正式入口二）
                SettingsNavRow(
                    icon: "sparkle",
                    iconColor: .holoPrimary,
                    title: String(localized: "HoloAI 设置"),
                    subtitle: String(localized: "一个发现、记忆与周期回放")
                ) {
                    showHoloAIUserSettings = true
                }
                .sheet(isPresented: $showHoloAIUserSettings) {
                    HoloAIUserSettingsView(
                        discoveryState: DiscoveryCoordinator.shared.settingsDetailState,
                        discoveryService: DiscoveryCoordinator.shared
                    )
                }

                SettingsRowDivider()

                SettingsNavRow(
                    icon: "lightbulb",
                    iconColor: .holoPrimary,
                    title: String(localized: "想法设置"),
                    subtitle: String(localized: "主题、标签与智能整理")
                ) {
                    showThoughtOrganizationSettings = true
                }
                .sheet(isPresented: $showThoughtOrganizationSettings) { ThoughtOrganizationSettingsView() }

            }
            .holoSurface()
        }
    }

    // MARK: - 数据与同步

    /// iCloud 同步 + 日历 + 数据管理（原 iCloud/日历/存储缓存/通用内数据管理四处归一；
    /// 缓存大小与清除缓存收进数据管理页）
    private var dataSyncSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
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

                SettingsRowDivider()

                SettingsNavRow(icon: "arrow.uturn.backward.circle", iconColor: .holoInfo,
                               title: "最近删除", subtitle: "找回 30 天内删除的记录") {
                    showRecycleBin = true
                }
                .sheet(isPresented: $showRecycleBin) { RecycleBinView() }
                .accessibilityIdentifier("settings.recentlyDeleted")

                SettingsRowDivider()

                SettingsNavRow(icon: "internaldrive", iconColor: .holoInfo,
                               title: "数据管理", subtitle: "记录数量、存储与缓存") {
                    showDataManagement = true
                }
                .sheet(isPresented: $showDataManagement) { DataManagementView() }

                SettingsRowDivider()

                SettingsNavRow(icon: "arrow.up.arrow.down", iconColor: .holoInfo,
                               title: "账单导入与导出", subtitle: "微信、支付宝与银行账单") {
                    showFinanceTransfer = true
                }
                .sheet(isPresented: $showFinanceTransfer) { SettingsFinanceTransferPage() }
                .accessibilityIdentifier("settings.financeTransfer")

                SettingsRowDivider()

                SettingsNavRow(icon: "calendar", iconColor: .holoInfo,
                               title: "日历接入", subtitle: "系统日历与任务同步") {
                    showCalendarPage = true
                }
                .sheet(isPresented: $showCalendarPage) {
                    SettingsSheetShell(String(localized: "日历接入")) {
                        ScheduleSettingsSection(showsSectionHeader: false)
                    }
                }
            }
            .holoSurface()
        }
    }

    /// iCloud 入口行副标题：与 iCloud 同步二级页的「账号状态」同源口径
    private var iCloudRowSubtitle: String {
        SettingsSyncCopy.summary(for: iCloudSyncStatus)
    }

    // MARK: - 隐私与安全

    /// 应用锁、AI 数据边界、小组件隐私与政策说明。
    private var privacySecuritySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "lock.shield.fill", title: "隐私与安全")

            VStack(spacing: 0) {
                SettingsToggleRow(
                    icon: "faceid",
                    iconColor: .holoPrimary,
                    title: String(localized: "应用锁"),
                    subtitle: appLockSubtitle,
                    isOn: appLockBinding
                )

                if appLockSettings.isEnabled {
                    SettingsRowDivider()

                    appLockGraceRow
                }

                SettingsRowDivider()

                SettingsNavRow(icon: "hand.raised", iconColor: .holoToolAI,
                               title: "AI 数据授权",
                               subtitle: aiConsent.isGranted ? String(localized: "已授权 · 可随时撤回") : String(localized: "未授权 · AI 处理已暂停")) {
                    showAIConsent = true
                }
                .sheet(isPresented: $showAIConsent) {
                    NavigationStack { AIDataProcessingConsentView() }
                }

                SettingsRowDivider()

                SettingsNavRow(icon: "eye.slash", iconColor: .holoToolAI,
                               title: "不参与 AI 的想法", subtitle: "按标签排除私密内容") {
                    showThoughtAIScope = true
                }
                .sheet(isPresented: $showThoughtAIScope) { ThoughtAIScopeSettingsView() }

                SettingsRowDivider()

                SettingsToggleRow(
                    icon: "text.quote",
                    iconColor: .holoPrimary,
                    title: String(localized: "小组件显示想法原文"),
                    subtitle: String(localized: "关闭后隐藏原文，仅显示来源"),
                    isOn: thoughtExcerptBinding
                )

                SettingsRowDivider()

                SettingsNavRow(icon: "doc.text.magnifyingglass", iconColor: .holoToolTextSecondary,
                               title: "隐私政策") {
                    showPrivacyPolicy = true
                }
                .sheet(isPresented: $showPrivacyPolicy) { LegalDocumentSheet(documentType: .privacyPolicy) }
            }
            .holoSurface()
        }
        .alert("无法开启应用锁", isPresented: $showAppLockUnavailableAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(appLockUnavailableMessage ?? "")
        }
    }

    private var appLockSubtitle: String {
        if !appLockSettings.isEnabled {
            return String(localized: "打开 Holo 时验证面容或设备密码")
        }
        return String(localized: "已开启 · \(appLockSettings.graceStyle.subtitle)")
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

    /// 锁定时机三档（立即 / 1 分钟 / 5 分钟，默认 5 分钟）
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
            HoloSettingsRow(icon: "clock.arrow.circlepath", title: "锁定时机", subtitle: appLockSettings.graceStyle.displayName) {
                HoloSettingsChevron()
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.xs)
            .contentShape(Rectangle())
        }
    }

    // MARK: - 通用

    /// 高频偏好前置，外观只显示当前值；帮助与反馈单独分组。
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "slider.horizontal.3", title: "使用偏好", color: .holoToolTextSecondary)

            VStack(spacing: 0) {
                // 外观：一级只留一行，右侧显示当前值，点开三选一
                SettingsNavRow(
                    icon: "moon.circle.fill",
                    iconColor: .holoPrimary,
                    title: String(localized: "外观"),
                    subtitle: "",
                    value: darkModeManager.currentSetting.displayName
                ) {
                    showAppearancePage = true
                }
                .sheet(isPresented: $showAppearancePage) {
                    SettingsAppearancePage()
                }

                SettingsRowDivider()

                // 统一通知中心入口（早报/习惯提醒/晨报/AI 回放的完整开关与时间都在这里）
                SettingsNavRow(
                    icon: "bell.badge",
                    iconColor: .holoPrimary,
                    title: String(localized: "通知设置"),
                    subtitle: String(localized: "提醒时间与通知权限")
                ) {
                    showNotificationSettings = true
                }
                .sheet(isPresented: $showNotificationSettings) {
                    NotificationSettingsView()
                }

            }
            .holoSurface()
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "questionmark.circle", title: "帮助与反馈")
            VStack(spacing: 0) {
                SettingsNavRow(icon: "questionmark.circle", iconColor: .holoInfo,
                               title: "使用帮助", subtitle: "新手引导与使用笔记") {
                    showHelp = true
                }
                .sheet(isPresented: $showHelp) {
                    SettingsHelpPage(onReplayCoachTour: replayCoachTour, onReplayWelcomeNote: replayWelcomeNote)
                }

                SettingsRowDivider()

                // 反馈给开发者
                SettingsNavRow(
                    icon: "ellipsis.bubble",
                    iconColor: .holoPrimary,
                    title: String(localized: "意见反馈"),
                    subtitle: String(localized: "报告问题或提出建议")
                ) {
                    showFeedback = true
                }
                .sheet(isPresented: $showFeedback) {
                    FeedbackSheet()
                }

                SettingsRowDivider()

                // 关于：版本 + 政策文档 + 重看引导（二级聚合页）
                SettingsNavRow(
                    icon: "info.circle",
                    iconColor: .holoInfo,
                    title: String(localized: "关于 Holo"),
                    subtitle: appVersionText
                ) {
                    showAbout = true
                }
                .sheet(isPresented: $showAbout) {
                    NavigationStack {
                        AboutView(onReplayCoachTour: replayCoachTour, onReplayWelcomeNote: replayWelcomeNote)
                    }
                }
            }
            .holoSurface()

        }
    }

    private func replayCoachTour() {
        if let onReturnHome { onReturnHome() } else { close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .replayHomeCoachTour, object: nil)
        }
    }

    private func replayWelcomeNote() {
        if let onReturnHome { onReturnHome() } else { close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            DeepLinkState.shared.navigate(to: .thoughtDetail(thoughtId: WelcomeNoteSeed.noteId))
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
                withAnimation(HoloAnimation.standard) {
                    developerOptionsExpanded.toggle()
                }
            } label: {
                HoloSettingsRow(icon: "wrench.and.screwdriver", iconColor: .holoToolTextSecondary,
                                title: "开发者选项", subtitle: "调试与实验工具") {
                    HoloSettingsChevron()
                        .rotationEffect(.degrees(developerOptionsExpanded ? 90 : 0))
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.xs)
                .holoSurface()
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

                    settingsRow(icon: "testtube.2", iconColor: .holoToolAI,
                                title: "AI 记忆实验室", subtitle: "记忆萃取与召回验证") {
                        showMemoryLab = true
                    }
                    .sheet(isPresented: $showMemoryLab) {
                        NavigationStack { AIMemoryLabView() }
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
        VStack(spacing: HoloSpacing.md) {
            if authService.isSignedIn {
                Button {
                    showSignOutConfirmation = true
                } label: {
                    HoloSettingsRow(icon: "rectangle.portrait.and.arrow.right", iconColor: .holoToolTextSecondary,
                                    title: "退出 Apple 登录", subtitle: "保留本机与 iCloud 数据")
                        .padding(.horizontal, HoloSpacing.md)
                }
                .buttonStyle(.plain)
                .holoSurface()
            }

            Button {
                showDeleteAccountDataConfirmation = true
            } label: {
                HoloSettingsRow(icon: "trash", iconColor: .holoToolError,
                                title: "删除账号与 Holo 数据", titleColor: .holoToolError,
                                subtitle: accountDataDeletionMessage ?? String(localized: "删除账号并清除数据，需再次确认")) {
                    if isDeletingAccountData { ProgressView().tint(.holoToolError) }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.xs)
                .holoSurface()
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
