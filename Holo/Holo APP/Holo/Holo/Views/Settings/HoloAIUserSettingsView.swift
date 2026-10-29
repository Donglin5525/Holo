//
//  HoloAIUserSettingsView.swift
//  Holo
//
//  统一 HoloAI 用户设置页（01 §4 分组表；Debug 与 Release 都可达）：
//  主条目（一个发现）／关于你（个人档案、长期记忆）／自动处理（想法智能整理、周期回放）／
//  数据与隐私（数据处理授权、不参与 AI 的想法、云端处理说明）。
//
//  只做页面与导航聚合：被引用的子视图（HoloProfileEditorView / PersonalMemorySettingsView /
//  ThoughtOrganizationSettingsView / ThoughtAIScopeSettingsView / AIDataProcessingConsentView）
//  一律原样复用，不改动其内部。开发者 Provider/Key/温度/Token/Prompt/Agent 调试
//  一概不进本页（仍独立 Debug 的 AISettingsView）。
//
//  本页自带 NavigationStack（与 PersonalView 同构，适合以 sheet 呈现；
//  若宿主要求 push 集成，把 body 内 HoloAIUserSettingsContent 拿出来用即可）。
//

import SwiftUI

struct HoloAIUserSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 「一个发现」主条目状态摘要（主会话观察服务后传入）
    let discoveryState: DiscoverySettingsDetailState
    let discoveryService: any DiscoveryService
    /// 长期记忆子页内「查看与管理记忆」（记忆长廊）的路由由主会话接
    var onOpenMemoryGallery: () -> Void = {}

    var body: some View {
        NavigationStack {
            HoloAIUserSettingsContent(
                discoveryState: discoveryState,
                discoveryService: discoveryService,
                onOpenMemoryGallery: onOpenMemoryGallery
            )
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navLeading) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("settings.holoai.close")
                }
            }
        }
    }
}

// MARK: - 页面内容（可脱离本页 NavigationStack 复用）

struct HoloAIUserSettingsContent: View {

    let discoveryState: DiscoverySettingsDetailState
    let discoveryService: any DiscoveryService
    var onOpenMemoryGallery: () -> Void = {}

    private enum Destination: String, Hashable {
        case discovery
        case memory
        case replay
    }

    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared
    @AppStorage(ThoughtSemanticFeatureFlags.automaticKey) private var thoughtOrganizeAutomatic = ThoughtSemanticFeatureFlags.automaticEnabled

    @State private var showsProfileEditor = false
    @State private var showsThoughtOrganization = false
    @State private var showsAIConsent = false
    @State private var showsCloudProcessingDetails = false
    @State private var showsThoughtAIScope = false
    #if DEBUG
    @State private var showsDeveloperAISettings = false
    #endif

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                Text("让 Holo 以你选择的方式理解你。")
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.horizontal, HoloSpacing.lg)

                mainGroup
                aboutYouGroup
                autoProcessingGroup
                privacyGroup
            }
            .padding(.vertical, HoloSpacing.md)
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("HoloAI 设置")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .discovery:
                DiscoverySettingsView(state: discoveryState, service: discoveryService)
            case .memory:
                PersonalMemorySettingsView(onOpenMemoryGallery: onOpenMemoryGallery)
            case .replay:
                replayTogglesCard
            }
        }
        .sheet(isPresented: $showsProfileEditor) {
            NavigationStack { HoloProfileEditorView() }
        }
        .sheet(isPresented: $showsThoughtOrganization) {
            ThoughtOrganizationSettingsView()
        }
        .sheet(isPresented: $showsAIConsent) {
            NavigationStack { AIDataProcessingConsentView() }
        }
        .sheet(isPresented: $showsThoughtAIScope) {
            ThoughtAIScopeSettingsView()
        }
    }

    // MARK: 主条目（首卡无组标题，与 prototype 同构）

    private var mainGroup: some View {
        HoloSettingsSection {
            NavigationLink(value: Destination.discovery) {
                HoloSettingsRow(
                    icon: "sparkles",
                    title: "一个发现",
                    subtitle: DiscoverySettingsCopy.summaryText(for: discoveryState),
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.holoai.main.discovery")
        }
    }

    // MARK: 关于你

    private var aboutYouGroup: some View {
        HoloSettingsSection(title: "关于你") {
            Button {
                showsProfileEditor = true
            } label: {
                HoloSettingsRow(
                    icon: "person.crop.circle",
                    iconColor: .holoInfo,
                    title: "个人档案",
                    subtitle: "你的角色与偏好",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.holoai.about.profile")

            HoloSettingsDivider()

            NavigationLink(value: Destination.memory) {
                HoloSettingsRow(
                    icon: "brain",
                    iconColor: .holoPurple,
                    title: "长期记忆",
                    subtitle: "记忆开关与内容管理",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.holoai.about.memory")
        }
    }

    // MARK: 自动处理

    private var autoProcessingGroup: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HoloSettingsSection(title: "自动处理") {
                Button {
                    showsThoughtOrganization = true
                } label: {
                    HoloSettingsRow(
                        icon: "notebook",
                        iconColor: .holoAI,
                        title: "想法设置",
                        subtitle: thoughtOrganizeAutomatic ? "已开启 · 主题归类与相关笔记" : "已关闭",
                        trailing: { HoloSettingsChevron() }
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.holoai.auto.organize")

                HoloSettingsDivider()

                NavigationLink(value: Destination.replay) {
                    HoloSettingsRow(
                        icon: "calendar.day.timeline.left",
                        iconColor: .holoSuccess,
                        title: "周期回放",
                        subtitle: replaySummary,
                        trailing: { HoloSettingsChevron() }
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.holoai.auto.replay")
            }

            if !consent.isGranted {
                Text("未授予数据处理授权：自动处理处于暂停状态，不会在后台运行。")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HoloSpacing.lg)
            }
        }
    }

    /// 周期回放行的状态摘要
    private var replaySummary: String {
        var parts: [String] = []
        if insightSettings.weeklyAutoGenerationEnabled { parts.append("每周观察") }
        if insightSettings.backgroundAutoGenerationEnabled { parts.append("日/月回放") }
        if insightSettings.weeklyReminderEnabled || insightSettings.monthlyReminderEnabled { parts.append("提醒") }
        return parts.isEmpty ? "未开启自动生成" : parts.joined(separator: " · ")
    }

    /// 周期回放开关区（单一真源 MemoryInsightScheduleSettings；与通知设置共用同一份
    /// 开关与时间，不重复注册通知——改的是同一个 shared 对象）
    private var replayTogglesCard: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                HoloSettingsSection(title: "自动生成") {
                    replayToggleRow(
                        title: "自动生成每周观察",
                        subtitle: "整理上周记录中的变化与联系",
                        isOn: $insightSettings.weeklyAutoGenerationEnabled,
                        axID: "settings.holoai.replay.weeklyObservation"
                    )
                    HoloSettingsDivider()
                    replayToggleRow(
                        title: "自动生成日/月回放",
                        subtitle: "后台整理日/月回放，未完成时在打开 Holo 后补充",
                        isOn: $insightSettings.backgroundAutoGenerationEnabled,
                        axID: "settings.holoai.replay.autoGeneration"
                    )
                }

                HoloSettingsSection(title: "提醒") {
                    replayToggleRow(
                        title: "每周提醒我生成周回放",
                        subtitle: insightSettings.weeklyReminderEnabled
                            ? "每周\(insightSettings.weeklyReminderWeekdayName) \(String(format: "%02d", insightSettings.weeklyReminderHour)):00"
                            : "默认关闭",
                        isOn: $insightSettings.weeklyReminderEnabled,
                        axID: "settings.holoai.replay.weeklyReminder"
                    )
                    HoloSettingsDivider()
                    replayToggleRow(
                        title: "每月提醒我生成月回放",
                        subtitle: insightSettings.monthlyReminderEnabled
                            ? "每月\(insightSettings.monthlyReminderDay)日 \(String(format: "%02d", insightSettings.monthlyReminderHour)):00"
                            : "默认关闭",
                        isOn: $insightSettings.monthlyReminderEnabled,
                        axID: "settings.holoai.replay.monthlyReminder"
                    )
                }

                if !consent.isGranted {
                    Text("AI 数据授权已关闭，自动生成暂停。可在「设置 → 隐私与安全 → AI 数据授权」中开启。")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, HoloSpacing.lg)
                }

                Text("提醒与自动生成分别控制。提醒时间可在「通知设置」中调整。")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HoloSpacing.lg)
            }
            .padding(.vertical, HoloSpacing.md)
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("周期回放")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func replayToggleRow(title: String, subtitle: String, isOn: Binding<Bool>, axID: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text(subtitle)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HoloSpacing.sm)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
                .disabled(!consent.isGranted)
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, HoloSpacing.sm)
        .accessibilityIdentifier(axID)
    }

    // MARK: 数据与隐私

    private var privacyGroup: some View {
        HoloSettingsSection(title: "数据与隐私") {
            Button {
                showsAIConsent = true
            } label: {
                HoloSettingsRow(
                    icon: "hand.raised.square",
                    title: "数据处理授权",
                    subtitle: consent.isGranted ? "已授权，可随时撤回" : "未授权，AI 功能暂停",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.holoai.privacy.consent")

            HoloSettingsDivider()

            Button {
                showsThoughtAIScope = true
            } label: {
                HoloSettingsRow(
                    icon: "eye.slash",
                    iconColor: .holoAIShieldTint,
                    title: "不参与 AI 的想法",
                    subtitle: "按标签排除，适用于全部 AI 处理",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.holoai.privacy.aiScope")

            HoloSettingsDivider()

            cloudProcessingRow

            #if DEBUG
            // 开发者 AI 调试（独立 Debug 子入口，不进正式用户能力；Provider/Key/模型/Prompt/Agent 调试）
            Button {
                showsDeveloperAISettings = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoToolTextSecondary)
                    Text("开发者 AI 设置")
                        .holoText(.supporting)
                        .foregroundColor(.holoToolTextSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .padding(.vertical, HoloSpacing.xs)
            }
            .accessibilityIdentifier("settings.holoai.debug.aiSettings")
            .sheet(isPresented: $showsDeveloperAISettings) {
                NavigationStack {
                    AISettingsView()
                }
            }
            #endif
        }
    }

    /// 云端处理说明（静态说明区：区分「主动分析」与「发现自动理解」两类场景）
    private var cloudProcessingRow: some View {
        DisclosureGroup(isExpanded: $showsCloudProcessingDetails) {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                cloudBullet(
                    title: "主动分析（你发起）",
                    detail: "对话、深度分析和周期回放会将你的问题及本次回答所需的必要记录片段，经 Holo 后端交给第三方 AI 或语音服务处理。"
                )
                cloudBullet(
                    title: "自动处理（按你的设置）",
                    detail: "想法智能整理、一个发现与周期回放按各自开关运行，只处理所需的必要内容；一个发现还受你选择的数据范围约束。"
                )
                cloudBullet(
                    title: "共同的边界",
                    detail: "撤回数据处理授权后，停止新的外部处理，一个发现随之关闭。你的原始记录不会被删除。"
                )
            }
            .padding(.bottom, HoloSpacing.sm)
        } label: {
            HoloSettingsRow(icon: "cloud", title: "云端处理说明", subtitle: "查看 AI 会处理哪些内容")
        }
        .tint(.holoToolTextSecondary)
        .accessibilityIdentifier("settings.holoai.privacy.cloudNote")
    }

    private func cloudBullet(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .holoText(.supporting)
                .fontWeight(.medium)
                .foregroundColor(.holoToolText)
            Text(detail)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
