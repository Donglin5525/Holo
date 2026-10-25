//
//  DiscoveryDetailSheet.swift
//  Holo
//
//  「一个发现」底部阅读面板（01 §2 冻结顺序）：
//  ① 「记录里的一个发现」+ 关闭 → ② 观察标题 → ③ 解释段 → ④ 「看看依据 · N 段记录」
//  → ⑤ 反馈（有点像／不太准确→原因四选一）→ ⑥ 「聊聊这个」主按钮 + 低强调「管理一个发现」。
//
//  打开期间不被新结果替换（isDetailPresented 由服务层管）；撤权/证据失效时由
//  外部置 invalidationText 并随后关闭——不因“阅读稳定”继续暴露旧内容。
//  本面板允许下拉关闭（退出＝不产生认可、不推断不感兴趣），故无 interactiveDismissDisabled，
//  也无需 sheetDismissGuard（项目规则：禁下拉的 sheet 才须配 guard）。
//
//  协议缺口（交付报告已列）：「不太准确」要求点击即生成最小否定记录并先撤下，
//  协议只有带 reason 的 submitFeedback；「暂时不说」路径目前无法落最小否定记录。
//

import SwiftUI

struct DiscoveryDetailSheet: View {

    /// 冻结展示的发现（进入面板时的快照；打开期间不被新结果替换）
    let finding: DiscoveryFindingPresentation?
    /// 撤权／失效说明：非 nil 时只显示失效说明态（反馈与主操作全部收起）
    var invalidationText: String? = nil
    /// 动作走注入的服务（反馈、草稿构建）
    let service: any DiscoveryService
    /// 打开真实原记录（sourceRef 由 EvidenceView 回调；路由由主会话接）
    let onOpenSource: (String) -> Void
    /// 低强调「管理一个发现」→ 跳设置子页（路由由主会话接）
    let onOpenSettings: () -> Void
    /// 「聊聊这个」→ 携带发现上下文的草稿进入对话（路由由主会话接）
    let onStartConversation: (DiscoveryConversationDraft) -> Void
    /// 请求关闭（呈现绑定与 isDetailPresented 同步由主会话负责）
    let onDismiss: () -> Void

    private enum FeedbackPhase {
        case reading            // 未反馈
        case acknowledged       // 有点像 → 已收到回执
        case reasonPicking      // 不太准确 → 原因四选一（半页）
    }

    @State private var feedbackPhase: FeedbackPhase = .reading
    @State private var showsEvidence = false

    var body: some View {
        if feedbackPhase == .reasonPicking {
            reasonScaffold
        } else {
            readingScaffold
        }
    }

    // MARK: - 阅读态

    private var readingScaffold: some View {
        HoloSheetScaffold(
            title: "记录里的一个发现",
            onClose: { onDismiss() },
            primaryTitle: "聊聊这个",
            primaryAction: { startConversation() },
            primaryDisabled: finding == nil || invalidationText != nil
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if let invalidationText {
                        invalidationCard(invalidationText)
                    } else if let finding {
                        findingContent(finding)
                    } else {
                        // openFinding 返回 nil（即时撤下）等边界：不显示过期内容
                        invalidationCard("这条发现已失效，不再展示。")
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func findingContent(_ finding: DiscoveryFindingPresentation) -> some View {
        // ② 观察标题：不设行数上限——大字体下允许换行，不截断意义
        Text(finding.title)
            .holoText(.sectionTitle)
            .foregroundStyle(Color.holoToolText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("chat.discovery.detail.title")

        // ③ 解释段前的观察范围（可含不确定性）
        Label {
            Text("观察范围 \(finding.timeRangeText)")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        } icon: {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .accessibilityIdentifier("chat.discovery.detail.timeRange")

        // ③ 解释段（多段原样呈现，含边界；无评分、无跨领域 KPI）
        ForEach(Array(finding.body.enumerated()), id: \.offset) { index, paragraph in
            Text(paragraph)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.discovery.detail.body.\(index + 1)")
        }

        // ④ 「看看依据 · N 段记录」（N=真实独立来源数）
        evidenceToggle(finding)

        if showsEvidence {
            DiscoveryEvidenceView(finding: finding, onOpenSource: onOpenSource)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        // ⑤ 可选反馈
        feedbackArea

        // ⑥ 低强调「管理一个发现」（主按钮「聊聊这个」由脚手架贴底呈现）
        Button {
            onOpenSettings()
        } label: {
            Text("管理一个发现")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.discovery.detail.manage")
    }

    // MARK: 失效说明态

    private func invalidationCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.holoToolWarning)
            Text(text)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(Color.holoToolSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
        }
        .accessibilityIdentifier("chat.discovery.detail.invalidation")
    }

    // MARK: 依据展开

    private func evidenceToggle(_ finding: DiscoveryFindingPresentation) -> some View {
        let count = DiscoveryEvidenceView.independentRecordSourceCount(in: finding)
        return Button {
            withAnimation(HoloAnimation.standard) { showsEvidence.toggle() }
        } label: {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "notebook.text")
                    .font(.system(size: 13, weight: .medium))
                Text(showsEvidence ? "收起依据 · \(count) 段记录" : "看看依据 · \(count) 段记录")
                    .holoText(.supporting)
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(showsEvidence ? 180 : 0))
            }
            .foregroundStyle(Color.holoToolAction)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.discovery.detail.evidenceToggle")
        .accessibilityHint(Text(showsEvidence ? "收起依据列表" : "展开依据列表"))
    }

    // MARK: 反馈

    @ViewBuilder
    private var feedbackArea: some View {
        switch feedbackPhase {
        case .reading:
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("这像你吗？")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                HStack(spacing: HoloSpacing.sm) {
                    Button {
                        submitAccurate()
                    } label: {
                        Label("有点像", systemImage: "hand.thumbsup")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .accessibilityIdentifier("chat.discovery.detail.feedback.accurate")

                    Button {
                        withAnimation(HoloAnimation.standard) { feedbackPhase = .reasonPicking }
                    } label: {
                        Label("不太准确", systemImage: "hand.thumbsdown")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .accessibilityIdentifier("chat.discovery.detail.feedback.inaccurate")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.discovery.detail.feedback")

        case .acknowledged:
            Label {
                Text("已收到。这条反馈不会写进长期记忆。")
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.holoToolSuccess)
            }
            .accessibilityIdentifier("chat.discovery.detail.feedback.acknowledged")

        case .reasonPicking:
            EmptyView()
        }
    }

    /// 有点像：只回执，不弹任务、不写长期记忆；幂等（回执后按钮收起，无法连点）
    private func submitAccurate() {
        withAnimation(HoloAnimation.standard) { feedbackPhase = .acknowledged }
        Task { await service.submitFeedback(.accurate) }
    }

    // MARK: 原因四选一（半页）

    /// 「不太准确」先撤下（视觉上已进入撤下态），再可选原因；选完即撤并关闭。
    private var reasonScaffold: some View {
        HoloSheetScaffold(
            title: "记录里的一个发现",
            onClose: { onDismiss() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text("这条发现已撤下。")
                        .holoText(.sectionTitle)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.discovery.detail.withdrawnTitle")

                    Text("可以不解释，也可以告诉 Holo 哪里不合适：")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        reasonRow("依据不对", subtitle: "引用和你的原记录对不上", reason: .wrongEvidence, axID: "wrongEvidence")
                        divider
                        reasonRow("理解不对", subtitle: "读出了记录里没有的含义", reason: .wrongUnderstanding, axID: "wrongUnderstanding")
                        divider
                        reasonRow("现在不适用", subtitle: "以前是这样，现在情况变了", reason: .notApplicableNow, axID: "notApplicableNow")
                        divider
                        reasonRow("不想看这类", subtitle: "之后少推这类观察，可在设置里恢复", reason: .notInterested, axID: "notInterested")
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.xs)
                    .holoSurface()

                    // TODO(协议缺口)：「暂时不说」也应落最小否定记录（01 §3 已生成最小否定记录，
                    // 点击后无需等联网）；协议缺无 reason 的撤下入口，主会话补协议后接线。
                    Button {
                        onDismiss()
                    } label: {
                        Text("暂时不说")
                            .holoText(.supporting)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.discovery.detail.reason.skip")
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var divider: some View {
        Divider().padding(.leading, 0)
    }

    private func reasonRow(_ title: String, subtitle: String, reason: DiscoveryInaccurateReason, axID: String) -> some View {
        Button {
            Task {
                await service.submitFeedback(.inaccurate(reason: reason))
                onDismiss()
            }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolText)
                    Text(subtitle)
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.discovery.detail.reason.\(axID)")
    }

    // MARK: 续聊

    /// 「聊聊这个」：构建携带发现上下文的可编辑草稿（不自动发送）；随后由主会话接对话
    private func startConversation() {
        guard let draft = service.buildConversationDraft() else { return }
        onStartConversation(draft)
        onDismiss()
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）
