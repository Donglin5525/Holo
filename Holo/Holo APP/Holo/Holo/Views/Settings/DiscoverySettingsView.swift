//
//  DiscoverySettingsView.swift
//  Holo
//
//  「一个发现」功能子页（01 §4 主条目行点入），结构对齐原型 discoverySettings：
//  hero（底座图标 + 标题 + 一句说明）→ 开关卡 → 当前状态（九态文案）→ 使用范围入口
//  → 反馈重置 → 「自动处理如何进行」入口。范围与处理说明各自下挂一页，见
//  DiscoverySettingsSubpages.swift。
//
//  状态由主会话观察服务后传入（UI 不自行观察服务实现）；动作走注入的 any DiscoveryService。
//
//  布局约定：HoloSettingsSection 自带 24pt 水平边距，本页外层 VStack 不得再包水平边距
//  （2026-10-28 挑刺：双重边距致卡片两侧各窄 24pt、与 hero 左缘错位）。
//
//  协议缺口（TODO 标注，主会话补协议后接线）：
//  ① 允许来源的修改不在 DiscoveryService（展示读 DiscoverySettings 本机真源；修改走
//     服务端 scope 语义的入口待补，范围页只读）；
//  ② 被抑制类别列表不在 DiscoveryService（反馈区仅提供全量重置入口）。
//

import SwiftUI

struct DiscoverySettingsView: View {

    /// 当前功能状态（settingsDetailState 九态；主会话观察服务后传入）
    let state: DiscoverySettingsDetailState
    let service: any DiscoveryService

    @State private var showsEnableSheet = false
    @State private var showsDisableConfirm = false
    @State private var showsResetConfirm = false
    @State private var showsConsent = false

    /// 允许来源展示（本机设置真源；编辑待服务端 scope 方法，见文件头 TODO ①）
    private var allowedDomains: Set<DiscoverySourceDomain> {
        DiscoverySettings.shared.snapshot().allowedDomains
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                heroCard
                toggleSection
                statusSection
                scopeSection
                scopeNote
                feedbackSection
                processingSection
            }
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("一个发现")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showsEnableSheet) {
            DiscoveryFirstEnableSheet(
                service: service,
                onOpenGlobalConsent: {
                    showsEnableSheet = false
                    showsConsent = true
                },
                onFinished: { _ in
                    showsEnableSheet = false
                }
            )
        }
        .sheet(isPresented: $showsConsent) {
            NavigationStack {
                AIDataProcessingConsentView()
            }
        }
        .alert("关闭「一个发现」？", isPresented: $showsDisableConfirm) {
            Button("暂不", role: .cancel) {}
            Button("关闭", role: .destructive) {
                Task { await service.disable() }
            }
        } message: {
            Text("会停止新的理解，并删除已生成的发现。你的原始记录和已有记忆不受影响。")
        }
        .alert("重置反馈与隐藏偏好？", isPresented: $showsResetConfirm) {
            Button("暂不", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task { await service.resetFeedbackSuppression() }
            }
        } message: {
            Text("清除你标记过的「不太准确」和「不想看这类」。不影响你的任何记录。")
        }
    }

    // MARK: - 头部（原型 hd-settinghero：36pt 圆角方块底座 + 标题 + 说明）

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.holoPrimary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.12))
                )
                .accessibilityHidden(true)
            Text("一个发现")
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)
            Text("从你允许的记录里，整理值得留意的变化与联系。")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .accessibilityIdentifier("settings.discovery.hero")
    }

    // MARK: - 功能开关

    // 区块容器不挂 accessibilityIdentifier：会被 AX 扁平化吞掉内部 Toggle 自己的 id
    private var toggleSection: some View {
        HoloSettingsSection {
            HStack(spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启一个发现")
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolText)
                    Text("只在对话页呈现，不发通知")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .tint(.holoPrimary)
                    .disabled(DiscoverySettingsCopy.isToggleDisabled(state))
                    .accessibilityLabel(Text("开启一个发现"))
                    .accessibilityIdentifier("settings.discovery.toggle")
            }
            .padding(.vertical, HoloSpacing.sm)

            HoloSettingsFootnote(text: "默认关闭。关闭不会删除你的原始记录，也不影响主动使用 HoloAI。")
        }
    }

    /// 开关只触发动作，值由传入状态驱动：首开未完成/被取消时自动回弹
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { DiscoverySettingsCopy.isEnabledState(state) },
            set: { wantsOn in
                if wantsOn {
                    showsEnableSheet = true
                } else {
                    showsDisableConfirm = true
                }
            }
        )
    }

    // MARK: - 当前状态（纯文字两行，与原型一致）

    private var statusSection: some View {
        HoloSettingsSection(title: "当前状态") {
            VStack(alignment: .leading, spacing: 2) {
                Text(DiscoverySettingsCopy.statusText(for: state))
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolText)
                Text(DiscoverySettingsCopy.statusDetailText(for: state))
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, HoloSpacing.sm)

            if state == .serverUnsupported {
                Button("重新尝试开启") { showsEnableSheet = true }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .accessibilityIdentifier("settings.discovery.retryEnable")
            }
        }
        .accessibilityIdentifier("settings.discovery.status")
    }

    // MARK: - 使用范围（入口行 → DiscoveryScopeView）

    private var scopeSection: some View {
        HoloSettingsSection(title: "使用范围") {
            NavigationLink {
                DiscoveryScopeView(allowedDomains: allowedDomains)
            } label: {
                HoloSettingsRow(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "允许使用的记录",
                    subtitle: "同时遵循「不参与 AI 的想法」规则",
                    trailing: {
                        HStack(spacing: HoloSpacing.xs) {
                            Text(scopeSummary)
                                .holoText(.metadata)
                                .foregroundColor(.holoToolTextSecondary)
                            HoloSettingsChevron()
                        }
                    }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.domains")
        }
    }

    private var scopeSummary: String {
        allowedDomains.isEmpty ? "未选择" : "\(allowedDomains.count) 类"
    }

    private var scopeNote: some View {
        Text("不会自动开启长期记忆。发现不是对你的定论——你可以查看依据、纠正或忽略。")
            .holoText(.metadata)
            .foregroundColor(.holoToolTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HoloSpacing.lg + HoloSpacing.md)
    }

    // MARK: - 反馈（「不太准确」与「不想看这类」共用一个重置入口）

    private var feedbackSection: some View {
        HoloSettingsSection(title: "反馈") {
            Button {
                showsResetConfirm = true
            } label: {
                HStack {
                    Text("重置反馈与隐藏偏好")
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .holoText(.body)
                .foregroundColor(.holoToolText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.feedbackReset")

            HoloSettingsFootnote(text: "清除你标记过的「不太准确」和「不想看这类」。这些反馈只存在本机。")
        }
    }

    // MARK: - 自动处理如何进行（入口行 → DiscoveryProcessingNoteView）

    private var processingSection: some View {
        HoloSettingsSection {
            NavigationLink {
                DiscoveryProcessingNoteView()
            } label: {
                HoloSettingsRow(
                    icon: "checkmark.shield",
                    title: "自动处理如何进行",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.processingNote")
        }
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
