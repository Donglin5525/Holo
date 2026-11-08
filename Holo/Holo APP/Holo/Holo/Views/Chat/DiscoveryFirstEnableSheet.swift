//
//  DiscoveryFirstEnableSheet.swift
//  Holo
//
//  「一个发现」首次开启流程（01 §5）：
//  说明卡（必要片段经 Holo 后端交第三方 AI、不承诺只在本地推理、不承诺每日/实时/一定有发现）
//  v3 单开关（2026-11-08 东林拍板）：不再选来源——开启即全七域，授权由全局 AI 授权决定。
//  处理 needsTakeoverConfirmation（他设备占用：接管后旧设备停）／needsGlobalConsent
//  （引导跳全局授权）／serverUnsupported（解释暂不可用）；任一步取消/失败保持关闭。
//

import SwiftUI

struct DiscoveryFirstEnableSheet: View {

    let service: any DiscoveryService
    /// 缺全局授权时引导跳转（宿主呈现 AIDataProcessingConsentView）；
    /// 跳转类回调不设默认空值，漏接=编译不过
    let onOpenGlobalConsent: () -> Void
    /// 流程结束统一收口：enabled=是否成功开启；主会话据此关闭本 sheet
    var onFinished: (Bool) -> Void

    /// v3 单开关口径：开启即全七域参与（域授权由全局 AI 授权与系统权限决定）。
    private let selectedDomains: Set<DiscoverySourceDomain> = Set(DiscoverySourceDomain.allCases)
    @State private var agreed = false
    @State private var isProcessing = false
    @State private var enableTask: Task<Void, Never>?
    /// 终态内联说明（失败保持关闭）
    @State private var outcomeMessage: String?
    /// 接管确认页（他设备占用）
    @State private var takeoverOwnerDeviceID: String?

    /// 全局授权真源（现有 HoloAIDataProcessingConsent；enable 的 needsGlobalConsent 兜底）
    private var globalConsentGranted: Bool {
        HoloAIFeatureFlags.aiDataProcessingConsentGranted
    }

    private var canSubmit: Bool {
        agreed && !isProcessing && globalConsentGranted
    }

    var body: some View {
        Group {
            if let ownerDeviceID = takeoverOwnerDeviceID {
                takeoverScaffold(ownerDeviceID: ownerDeviceID)
            } else {
                formScaffold
            }
        }
        .onDisappear { enableTask?.cancel() }
    }

    // MARK: - 表单态

    private var formScaffold: some View {
        HoloSheetScaffold(
            title: "开启一个发现",
            onClose: close,
            primaryTitle: isProcessing ? "正在开启…" : (outcomeMessage == nil ? "同意并开启" : "重试开启"),
            primaryAction: { submit() },
            primaryDisabled: !canSubmit,
            primaryHint: submitHint,
            primaryAccessory: { agreeToggle.disabled(isProcessing) }
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        explanationCard

                        consentStatusCard

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
                            .id("enableOutcome")
                        }
                    }
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.vertical, HoloSpacing.md)
                }
                .onChange(of: outcomeMessage) { _, message in
                    if message != nil {
                        withAnimation(HoloAnimation.quick) { proxy.scrollTo("enableOutcome", anchor: .bottom) }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isProcessing)
    }

    /// 主按钮置灰原因（满足条件即 nil）。授权缺失不在此提示——授权卡内已有引导按钮，
    /// 两处重复反而模糊主引导（§4.5 同屏不重复同一指引）。
    private var submitHint: String? {
        guard !canSubmit, outcomeMessage == nil else { return nil }
        if !agreed { return "打开下方的同意开关后即可开启" }
        return nil
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

            bullet("你允许 AI 使用的记录都会参与找规律：想法、任务、习惯、目标、对话、财务、健康。已设为「不参与 AI」的想法始终排除。", icon: "scope")
            bullet("规律由这台设备上的统计算出。为了让文案自然，少量统计特征（如分类名、指标名、变化方向）会经 Holo 后端交给第三方 AI 撰写；金额、健康原始数值和记录原文不会发送。", icon: "arrow.triangle.branch")
            bullet("每天至多一条，可先展开核对依据再确认；不发通知。", icon: "calendar")
            bullet("可随时关闭，关闭即停，不删除你的原始记录。确认过的规律保存在记忆里，随 iCloud 同步。", icon: "icloud")
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
        enableTask = Task {
            let outcome = await service.enable(
                selectedDomains: selectedDomains,
                confirmTakeoverIfOwnedByOtherDevice: confirmTakeover
            )
            guard !Task.isCancelled else { return }
            isProcessing = false
            handle(outcome)
        }
    }

    private func close() {
        enableTask?.cancel()
        onFinished(false)
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
            outcomeMessage = "发现服务暂未开放，一个发现尚未开启。请稍后再试。"
        case .noDomainSelected:
            outcomeMessage = "至少选择一类来源后再开启。"
        case .cancelled:
            outcomeMessage = "本次开启已取消，一个发现保持关闭。"
        case .failed(let failure):
            outcomeMessage = failure.message
        }
    }

    // MARK: 接管确认（他设备占用：单设备租约）

    private func takeoverScaffold(ownerDeviceID: String) -> some View {
        HoloSheetScaffold(
            title: "开启一个发现",
            onClose: close,
            primaryTitle: isProcessing ? "正在切换设备…" : "在本设备接管",
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

                    if let outcomeMessage {
                        HoloInlineState(kind: .failure, message: outcomeMessage)
                            .accessibilityIdentifier("chat.discovery.enable.takeover.outcome")
                    }

                    Button {
                        close()
                    } label: {
                        Text("暂不接管，保持关闭")
                            .holoText(.supporting)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                    .accessibilityIdentifier("chat.discovery.enable.takeover.cancel")
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isProcessing)
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
