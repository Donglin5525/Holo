//
//  DiscoverySettingsView.swift
//  Holo
//
//  「一个发现」功能子页（01 §4 主条目行点入）：开关（含首开流程触发）、
//  状态行（九态映射文案）、允许来源、「已隐藏的发现」管理、重置本功能反馈、处理说明。
//
//  状态由主会话观察服务后传入（UI 不自行观察服务实现）；动作走注入的 any DiscoveryService。
//
//  协议缺口（TODO 标注，主会话补协议后接线）：
//  ① 允许来源的读取/修改不在 DiscoveryService（当前展示读 DiscoverySettings 本机真源，
//     修改走服务端 scope 语义的入口待补，编辑态 disabled）；
//  ② 被抑制类别列表不在 DiscoveryService（「已隐藏的发现」列表暂空态，恢复走
//     resetFeedbackSuppression 全量入口）。
//

import SwiftUI

struct DiscoverySettingsView: View {

    /// 当前功能状态（settingsDetailState 九态；主会话观察服务后传入）
    let state: DiscoverySettingsDetailState
    let service: any DiscoveryService
    /// 缺全局授权时引导跳转（与首开 sheet 共用路由）
    var onOpenGlobalConsent: () -> Void = {}

    @State private var showsEnableSheet = false
    @State private var showsDisableConfirm = false
    @State private var showsResetConfirm = false

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
                domainsSection
                hiddenSection
                feedbackResetSection
                processingNoteSection
            }
            .padding(.horizontal, HoloSpacing.lg)
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
                    onOpenGlobalConsent()
                },
                onFinished: { _ in
                    showsEnableSheet = false
                }
            )
        }
        .confirmationDialog(
            "关闭「一个发现」？",
            isPresented: $showsDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("关闭", role: .destructive) {
                Task { await service.disable() }
            }
            Button("暂不", role: .cancel) {}
        } message: {
            Text("将停止新的自动理解，并清除已生成的发现与派生缓存；你的原始记录与已有记忆不受影响。")
        }
        .confirmationDialog(
            "重置本功能反馈？",
            isPresented: $showsResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                Task { await service.resetFeedbackSuppression() }
            }
            Button("暂不", role: .cancel) {}
        } message: {
            Text("清除你对「一个发现」的否定反馈与「不想看这类」的隐藏偏好；不影响任何业务数据。")
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
                    .disabled(DiscoverySettingsCopy.isToggleDisabled(state))
                    .accessibilityLabel(Text("开启一个发现"))
                    .accessibilityIdentifier("settings.discovery.toggle")
            }
            .padding(.vertical, HoloSpacing.sm)

            HoloSettingsFootnote(text: "默认关闭。关闭不删除原始记录，也不影响你主动使用 HoloAI 对话与深度分析。")
        }
        .accessibilityIdentifier("settings.discovery.toggleSection")
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

    // MARK: - 当前状态

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

    // MARK: - 允许来源

    private var domainsSection: some View {
        HoloSettingsSection(title: "允许使用的记录") {
            ForEach(DiscoveryDomainMeta.all) { meta in
                domainRow(meta)
            }
            // TODO(协议缺口 ①)：改动需走服务端 scope 语义（撤销旧批次/更新范围版本/
            // 扩大需再次确认），DiscoveryService 暂无 updateAllowedDomains；补上后
            // 打开编辑并把本机展示切到服务状态，见文件头说明。
            HoloSettingsFootnote(text: "改动后会重新核验已有发现；同时遵循「不参与 AI 的想法」的排除规则。")
        }
        .accessibilityIdentifier("settings.discovery.domains")
    }

    private func domainRow(_ meta: DiscoveryDomainMeta) -> some View {
        let allowed = allowedDomains.contains(meta.domain)
        return HStack(spacing: HoloSpacing.sm) {
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

            Image(systemName: allowed ? "checkmark" : "minus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(allowed ? Color.holoPrimary : Color.holoToolTextSecondary.opacity(0.5))
        }
        .padding(.vertical, HoloSpacing.sm)
        .accessibilityIdentifier("settings.discovery.domains.\(meta.domain.rawValue)")
        .accessibilityLabel(Text("允许使用\(meta.title)"))
        .accessibilityValue(Text(allowed ? "已允许" : "未允许"))
    }

    // MARK: - 已隐藏的发现

    private var hiddenSection: some View {
        HoloSettingsSection(title: "已隐藏的发现") {
            // TODO(协议缺口 ②)：被抑制类别/主题列表不在 DiscoveryService，补上后替换空态；
            // 列表不得泄露被排除原文（01 §3），只展示类别与操作。
            VStack(alignment: .leading, spacing: 2) {
                Text("你选择过「不想看这类」的观察类别会列在这里，可随时恢复偏好。")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HoloSpacing.sm)
            .accessibilityIdentifier("settings.discovery.hidden.empty")

            Button {
                showsResetConfirm = true
            } label: {
                HStack {
                    Text("恢复全部偏好")
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                }
                .holoText(.body)
                .foregroundColor(.holoToolText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.discovery.hidden.restore")
        }
        .accessibilityIdentifier("settings.discovery.hiddenSection")
    }

    // MARK: - 重置本功能反馈

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

            HoloSettingsFootnote(text: "反馈明细只保存在本机，不上传文本。")
        }
        .accessibilityIdentifier("settings.discovery.feedbackSection")
    }

    // MARK: - 处理说明（静态）

    private var processingNoteSection: some View {
        HoloSettingsSection(title: "处理说明") {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                processingBullet("有新材料时，Holo 自动把你允许范围内的必要片段，通过 Holo 后端交给第三方 AI 理解并核验；不承诺只在本地推理。", icon: "arrow.triangle.branch")
                processingBullet("先有依据、再呈现：记录不足或解释不可靠时不展示；呈现的发现都附可打开的记录依据。", icon: "checkmark.shield")
                processingBullet("不承诺每日、实时或一定有发现；不发通知、不打扰。", icon: "bell.slash")
                processingBullet("关闭即停止：取消未完成任务并删除派生内容；已发出的请求尽力取消，迟到结果不再采纳。", icon: "stop.circle")
                processingBullet("V1 不读取长期记忆，也不写入长期记忆。", icon: "brain")
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .accessibilityIdentifier("settings.discovery.processingNote")
    }

    private func processingBullet(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
