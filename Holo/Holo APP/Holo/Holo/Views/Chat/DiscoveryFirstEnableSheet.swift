//
//  DiscoveryFirstEnableSheet.swift
//  Holo
//
//  「一个发现」首次开启流程（01 §5）：
//  说明卡（必要片段经 Holo 后端交第三方 AI、不承诺只在本地推理、不承诺每日/实时/一定有发现）
//  → 来源多选（想法/任务/习惯，默认全不选，至少选一）→ 同意勾选 → 「同意并开启」。
//  处理 needsTakeoverConfirmation（他设备占用：接管后旧设备停）／needsGlobalConsent
//  （引导跳全局授权）／serverUnsupported（解释暂不可用）；任一步取消/失败保持关闭。
//

import SwiftUI

struct DiscoveryFirstEnableSheet: View {

    let service: any DiscoveryService
    /// 缺全局授权时引导跳转（主会话呈现 AIDataProcessingConsentView）
    var onOpenGlobalConsent: () -> Void = {}
    /// 流程结束统一收口：enabled=是否成功开启；主会话据此关闭本 sheet
    var onFinished: (Bool) -> Void

    @State private var selectedDomains: Set<DiscoverySourceDomain> = []
    @State private var agreed = false
    @State private var isProcessing = false
    /// 终态内联说明（失败保持关闭）
    @State private var outcomeMessage: String?
    /// 接管确认页（他设备占用）
    @State private var takeoverOwnerDeviceID: String?

    /// 全局授权真源（现有 HoloAIDataProcessingConsent；enable 的 needsGlobalConsent 兜底）
    private var globalConsentGranted: Bool {
        HoloAIFeatureFlags.aiDataProcessingConsentGranted
    }

    private var canSubmit: Bool {
        !selectedDomains.isEmpty && agreed && !isProcessing && globalConsentGranted
    }

    var body: some View {
        if let ownerDeviceID = takeoverOwnerDeviceID {
            takeoverScaffold(ownerDeviceID: ownerDeviceID)
        } else {
            formScaffold
        }
    }

    // MARK: - 表单态

    private var formScaffold: some View {
        HoloSheetScaffold(
            title: "开启一个发现",
            onClose: { onFinished(false) },
            primaryTitle: "同意并开启",
            primaryAction: { submit() },
            primaryDisabled: !canSubmit
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    explanationCard

                    consentStatusCard

                    domainCard

                    agreeToggle

                    if isProcessing {
                        HoloInlineState(kind: .loading, message: "正在开启…")
                            .accessibilityIdentifier("chat.discovery.enable.processing")
                    }

                    if let outcomeMessage {
                        Label {
                            Text(outcomeMessage)
                                .holoText(.supporting)
                                .foregroundStyle(Color.holoToolText)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.holoToolTextSecondary)
                        }
                        .accessibilityIdentifier("chat.discovery.enable.outcome")
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.large])
    }

    // MARK: 说明卡（01 §5 必须明示的三件事）

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.holoPrimary)
                .accessibilityHidden(true)
            Text("让 Holo 安静地理解一些记录。")
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)

            bullet("开启后，有新材料时 Holo 会自动把你选择范围内的必要片段，通过 Holo 后端交给第三方 AI 理解与核验——不承诺只在本地推理。", icon: "arrow.triangle.branch")
            bullet("不承诺每日、实时或一定有发现；记录不足或解释不可靠时不呈现。", icon: "calendar.badge.minus")
            bullet("只在对话页呈现，不发通知；可随时关闭，关闭不删除你的原始记录。", icon: "bell.slash")
            bullet("不读取长期记忆，无需为此开启自动记忆。", icon: "brain")
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityIdentifier("chat.discovery.enable.explanation")
    }

    private func bullet(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 全局授权状态

    private var consentStatusCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: globalConsentGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(globalConsentGranted ? Color.holoToolSuccess : Color.holoToolWarning)
                    .accessibilityHidden(true)
                Text(globalConsentGranted ? "已获得 HoloAI 数据处理授权" : "尚未获得 HoloAI 数据处理授权")
                    .holoText(.supporting)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.holoToolText)
            }

            if !globalConsentGranted {
                Text("「一个发现」的自动理解同样依赖总授权。请先到「数据处理授权」了解并同意，再回来开启。")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onOpenGlobalConsent()
                } label: {
                    Text("查看数据处理授权")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoloActionStyle(role: .secondary))
                .accessibilityIdentifier("chat.discovery.enable.openConsent")
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolInset.opacity(0.5))
        )
        .accessibilityIdentifier("chat.discovery.enable.consentStatus")
    }

    // MARK: 来源多选（默认全不选）

    private var domainCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("允许理解的范围")
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
            Text("至少选择一类；同时遵循「不参与 AI 的想法」排除规则。V1 不读取健康与财务记录。")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(DiscoveryDomainMeta.all.enumerated()), id: \.element.id) { index, meta in
                    if index > 0 { Divider() }
                    domainRow(meta)
                }
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.enable.domains")
    }

    private func domainRow(_ meta: DiscoveryDomainMeta) -> some View {
        let isSelected = selectedDomains.contains(meta.domain)
        return Button {
            withAnimation(HoloAnimation.quick) {
                if isSelected {
                    selectedDomains.remove(meta.domain)
                } else {
                    selectedDomains.insert(meta.domain)
                }
            }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: meta.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.holoPrimary.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolText)
                    Text(meta.subtitle)
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? Color.holoPrimary : Color.holoToolTextSecondary.opacity(0.5))
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.discovery.enable.domain.\(meta.domain.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(Text("允许理解\(meta.title)"))
    }

    // MARK: 同意勾选

    private var agreeToggle: some View {
        Toggle(isOn: $agreed) {
            Text("我了解并同意上述说明")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
        }
        .tint(.holoPrimary)
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityIdentifier("chat.discovery.enable.agree")
    }

    // MARK: 提交与结果处理

    private func submit(confirmTakeover: Bool = false) {
        guard canSubmit || confirmTakeover else { return }
        isProcessing = true
        outcomeMessage = nil
        Task {
            let outcome = await service.enable(
                selectedDomains: selectedDomains,
                confirmTakeoverIfOwnedByOtherDevice: confirmTakeover
            )
            isProcessing = false
            handle(outcome)
        }
    }

    /// needsTakeoverConfirmation 重入时允许直接提交（勾选与范围已确认过）
    private func handle(_ outcome: DiscoveryEnableOutcome) {
        switch outcome {
        case .enabled:
            onFinished(true)
        case .needsTakeoverConfirmation(let ownerDeviceID):
            takeoverOwnerDeviceID = ownerDeviceID
        case .needsGlobalConsent:
            outcomeMessage = "缺少 HoloAI 数据处理授权，请先完成授权；开关保持关闭。"
        case .serverUnsupported:
            outcomeMessage = "当前版本暂不支持此功能，开关保持关闭。"
        case .noDomainSelected:
            outcomeMessage = "至少选择一类来源后再开启。"
        case .cancelled:
            outcomeMessage = "未能开启，设置保持关闭。你可以稍后再试。"
        }
    }

    // MARK: 接管确认（他设备占用：单设备租约）

    private func takeoverScaffold(ownerDeviceID: String) -> some View {
        HoloSheetScaffold(
            title: "开启一个发现",
            onClose: { onFinished(false) },
            primaryTitle: "在本设备接管",
            primaryAction: { submit(confirmTakeover: true) },
            primaryDisabled: isProcessing
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.holoToolWarning)
                    Text("「一个发现」已在另一台设备开启")
                        .holoText(.sectionTitle)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.discovery.enable.takeover.title")

                    Text("「一个发现」同一时间只在一台设备上自动理解。在本设备接管后，\(ownerDeviceID) 将停止自动理解，原设备上已生成的发现也会撤下。")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)

                    if isProcessing {
                        HoloInlineState(kind: .loading, message: "正在切换设备…")
                    }

                    Button {
                        onFinished(false)
                    } label: {
                        Text("暂不接管，保持关闭")
                            .holoText(.supporting)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.discovery.enable.takeover.cancel")
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
