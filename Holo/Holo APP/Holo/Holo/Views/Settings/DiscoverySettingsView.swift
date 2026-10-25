//
//  DiscoverySettingsView.swift
//  Holo
//
//  「一个发现」功能子页（01 §4 主条目行点入）：开关（含首开流程触发）、
//  状态行（九态映射文案）、允许来源展示、「自动处理如何进行」子页入口、重置反馈。
//
//  状态由 DiscoverySettingsWatcher 持有（与统一设置页主条目共用同一份发布）；
//  每次动作完成（开启/关闭/重置）后页面显式 reload()，开关与状态立即跟上。
//
//  V1.1 待办（协议缺口，见实施进度）：允许来源的修改需服务端 scope 语义
//  （撤销旧批次/更新范围版本/扩大需再次确认），本页只读展示「开启时选定」的范围；
//  被抑制类别列表不在 DiscoveryService，重置走 resetFeedbackSuppression 全量入口。
//

import SwiftUI

struct DiscoverySettingsView: View {

    let service: any DiscoveryService
    /// 页面与统一设置页主条目共享的状态源；动作后 reload() 即时跟上
    @ObservedObject var watcher: DiscoverySettingsWatcher
    /// 缺全局授权时引导跳转（与首开 sheet 共用路由）
    var onOpenGlobalConsent: () -> Void = {}

    @State private var showsEnableSheet = false
    @State private var showsDisableConfirm = false
    @State private var showsResetConfirm = false
    @State private var showsProcessingNote = false
    /// 重置完成回执（两秒半自清）
    @State private var showsResetDone = false

    private var state: DiscoverySettingsDetailState { watcher.detailState }
    private var isFeatureOn: Bool { DiscoverySettingsCopy.isEnabledState(state) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                heroCard
                toggleSection
                if state != .disabled {
                    statusSection
                }
                if isFeatureOn {
                    domainsSection
                }
                processingRowSection
                feedbackResetSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoToolBackground.ignoresSafeArea())
        .navigationTitle("一个发现")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { watcher.reload() }
        .navigationDestination(isPresented: $showsProcessingNote) {
            DiscoveryProcessingNoteView()
        }
        .sheet(isPresented: $showsEnableSheet) {
            DiscoveryFirstEnableSheet(
                service: service,
                onOpenGlobalConsent: {
                    showsEnableSheet = false
                    onOpenGlobalConsent()
                },
                onFinished: { enabled in
                    showsEnableSheet = false
                    if enabled {
                        watcher.reload()
                    }
                }
            )
        }
        .alert("关闭「一个发现」？", isPresented: $showsDisableConfirm) {
            Button("暂不", role: .cancel) {}
            Button("关闭", role: .destructive) {
                Task {
                    await service.disable()
                    watcher.reload()
                }
            }
        } message: {
            Text("将停止自动理解，并清除已生成的发现；你的原始记录与已有记忆不受影响。")
        }
        .alert("重置本功能反馈？", isPresented: $showsResetConfirm) {
            Button("暂不", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task {
                    await service.resetFeedbackSuppression()
                    watcher.reload()
                    showsResetDone = true
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        showsResetDone = false
                    }
                }
            }
        } message: {
            Text("清除你给过的「不太准确」与「不想看这类」反馈；不影响任何业务数据。")
        }
    }

    // MARK: - 头部说明

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.holoPrimary)
                .accessibilityHidden(true)
            Text("让 AI 从你允许的记录里，整理值得留意的变化与联系。")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.discovery.hero")
    }

    // MARK: - 功能开关

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
                    .disabled(!isFeatureOn && state == .serverUnsupported)
                    .accessibilityLabel(Text("开启一个发现"))
                    .accessibilityIdentifier("settings.discovery.toggle")
            }
            .padding(.vertical, HoloSpacing.sm)

            HoloSettingsFootnote(text: "默认关闭。关闭后停止整理并移除对话页入口，不影响你的原始记录与主动聊天。")
        }
        // 注意：不要在区块容器上挂 accessibilityIdentifier——这里唯一可交互元素是开关，
        // 区块标识符会被 AX 扁平化吞掉开关自身的 settings.discovery.toggle（XCUITest 实证）
    }

    /// 开关只触发动作，值由状态驱动：首开未完成/被取消时自动回弹
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isFeatureOn },
            set: { wantsOn in
                if wantsOn {
                    showsEnableSheet = true
                } else {
                    showsDisableConfirm = true
                }
            }
        )
    }

    // MARK: - 当前状态（关闭态由开关本身表达，不再单列）

    private var statusSection: some View {
        HoloSettingsSection(title: "当前状态") {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.holoPrimary.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(DiscoverySettingsCopy.statusText(for: state))
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolText)
                    Text(DiscoverySettingsCopy.statusDetailText(for: state))
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .accessibilityIdentifier("settings.discovery.status")
    }

    private var statusIcon: String {
        switch state {
        case .disabled, .revoked: return "moon.zzz"
        case .preparing: return "hourglass"
        case .waitingForMaterial, .stale: return "tray"
        case .hasFinding: return "sparkles"
        case .pausedTemporarily: return "wifi.exclamationmark"
        case .serverUnsupported: return "exclamationmark.circle"
        }
    }

    // MARK: - 允许来源（只读展示开启时选定的范围）

    private var domainsSection: some View {
        HoloSettingsSection(title: "允许使用的记录") {
            ForEach(DiscoveryDomainMeta.all.filter { watcher.allowedDomains.contains($0.domain) }) { meta in
                domainRow(meta)
            }
            HoloSettingsFootnote(text: "开启时选定；同时遵循「不参与 AI 的想法」的排除规则。")
        }
        .accessibilityIdentifier("settings.discovery.domains")
    }

    private func domainRow(_ meta: DiscoveryDomainMeta) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: meta.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.holoPrimary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text(meta.subtitle)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HoloSpacing.sm)

            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.holoPrimary)
        }
        .padding(.vertical, HoloSpacing.sm)
        .accessibilityIdentifier("settings.discovery.domains.\(meta.domain.rawValue)")
        .accessibilityLabel(Text("允许使用\(meta.title)"))
        .accessibilityValue(Text("已允许"))
    }

    // MARK: - 处理说明入口

    private var processingRowSection: some View {
        HoloSettingsSection {
            Button {
                showsProcessingNote = true
            } label: {
                HoloSettingsRow(
                    icon: "cloud",
                    title: "自动处理如何进行",
                    subtitle: "必要数据如何交给外部 AI，有什么边界",
                    trailing: { HoloSettingsChevron() }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.processingRow")
        }
    }

    // MARK: - 重置本功能反馈（唯一入口；原「恢复全部偏好」与此重复，已合并）

    private var feedbackResetSection: some View {
        HoloSettingsSection(title: "反馈") {
            Button {
                showsResetConfirm = true
            } label: {
                HStack {
                    Text("重置本功能反馈")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                }
                .holoText(.body)
                .foregroundColor(.holoToolText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.feedbackReset")

            if showsResetDone {
                Label {
                    Text("已重置，之前隐藏过的类别之后可能再次出现。")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.holoToolSuccess)
                }
                .padding(.bottom, HoloSpacing.xs)
                .accessibilityIdentifier("settings.discovery.resetDone")
            }

            HoloSettingsFootnote(text: "反馈只保存在本机，不上传原文。")
        }
        .accessibilityIdentifier("settings.discovery.feedbackSection")
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
