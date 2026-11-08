import SwiftUI
import Combine

struct DiscoverySheetContent: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        // v3：旧「服务端发布发现卡」阅读面板已退役，统一进入本机规律评审页。
        DiscoveryReviewSheet(onClose: { viewModel.closeDiscoveryDetail() })
    }
}

struct DiscoveryReviewSheet: View {
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @State private var result: DiscoveryMemoryReviewService.Result?
    @State private var refreshID = 0
    @State private var itemIndex = 0
    @State private var failed = false
    @State private var actionNotice: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var showsEvidence = false
    @State private var todayCard: DiscoveryTopicStore.QueuedCard?
    @State private var showsTodayEvidence = false

    private let service = DiscoveryMemoryReviewService()

    var body: some View {
        HoloSheetScaffold(title: "一个发现", onClose: onClose) {
            ScrollView {
                    VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                        intro
                        if let card = todayCard, result != nil {
                            todayCardSection(card)
                        }
                        if consent.isGranted && !service.domains.isEmpty {
                            reviewContent
                    } else {
                        HoloInlineState(kind: .empty, message: "开启「一个发现」并允许使用记录后，这里会显示可以核对的规律。")
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.large])
        .task(id: refreshID) { await reload() }
        .onChange(of: consent.isGranted) { _, _ in requestRefresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { requestRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoDiscoverySettingsDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .holoKnowledgeControlDidApply)) { _ in
            if actionTask == nil { requestRefresh() }
        }
        .onDisappear { actionTask?.cancel() }
    }

    private var intro: some View {
        // B 风格定稿：引导区保留但降一档（18pt），不与发现句抢标题位。
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Image(systemName: "sparkle")
                .font(.body)
                .foregroundStyle(Color.holoPrimary)
                .accessibilityHidden(true)
            Text("记录里，藏着一些规律")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
            Text("Holo 找到反复出现的记录时，会请你核对一次。")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .accessibilityIdentifier("chat.discovery.review.intro")
    }

    @ViewBuilder
    private var reviewContent: some View {
        if let actionNotice {
            Text(actionNotice)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .accessibilityIdentifier("chat.discovery.review.receipt")
        }
        if let result {
            // 今日一条与列表不重复：今日卡对应的条目从列表过滤（#6）
            let listedItems = result.items.filter { item in
                guard let card = todayCard else { return true }
                return item.proposal?.propositionID != card.topicKey && item.proposal?.topicID != card.topicKey
            }
            if listedItems.indices.contains(itemIndex) {
                let item = listedItems[itemIndex]
                DiscoveryReviewCard(
                    knowledge: item.knowledge, showsEvidence: $showsEvidence,
                    isApplying: actionTask != nil,
                    // 一屏一个主操作（§8.8-2）：有今日卡时列表的「对，记住」降为描边次级。
                    elevatesPrimary: todayCard == nil,
                    onAction: { apply($0, to: item) }
                )
                if listedItems.count > 1 {
                    Button {
                        showsEvidence = false
                        itemIndex = (itemIndex + 1) % listedItems.count
                    } label: {
                        Text("看下一条 · \(itemIndex + 1) / \(listedItems.count)")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.holoToolAction)
                    .disabled(actionTask != nil)
                    .accessibilityIdentifier("chat.discovery.review.next")
                }
            } else if todayCard == nil {
                // 空态四件套：图标+标题+说明+动作（无今日卡且列表空才算真空态）。
                VStack(spacing: HoloSpacing.sm) {
                    HoloInlineState(kind: .empty, message: "今天没有新发现。同一件事在不同的日子反复出现，Holo 就会拿来问你一句。")
                        .accessibilityIdentifier("chat.discovery.review.empty")
                    Button("看看已经记住的") { DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false)) }
                        .buttonStyle(HoloActionStyle(role: .secondary))
                        .accessibilityIdentifier("chat.discovery.review.openMemory")
                }
            }
            if let notice = result.healthNotice {
                healthNotice(notice)
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        } else if failed {
            // 失败必须可重试（§12）：不再指向已删除的「重新整理」。
            VStack(spacing: HoloSpacing.sm) {
                HoloInlineState(kind: .failure, message: "这次没读完你的记录。")
                    .accessibilityIdentifier("chat.discovery.review.error")
                Button("再试一次") { requestRefresh() }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .accessibilityIdentifier("chat.discovery.review.retry")
            }
        } else {
            HoloInlineState(kind: .loading, message: "正在翻你最近的记录…")
                .accessibilityIdentifier("chat.discovery.review.loading")
        }
    }

    private func healthNotice(_ notice: DiscoveryMemoryReviewService.HealthNotice) -> Text {
        switch notice {
        case .noReadings:
            // 单开关口径：没授权过健康=用户自己的选择，不再常驻提醒；
            // 已授权但无读数才提示（一次性邀请语义由内容自然表达）。
            HealthRepository.shared.hasRequestedPermission
                ? Text("最近没读到步数和睡眠，可以去 iPhone 自带的「健康」App 看看权限。")
                : Text("连上健康数据，能多发现睡眠和步数的规律。")
        case .waitingForUnlock: Text("有几条健康数据要等手机解锁才能读，解锁后这里会自动更新。")
        case .unavailable: Text("健康数据这次没读到，过会儿再打开看看。")
        }
    }

    private func requestRefresh() {
        // 刷新不闪屏：保留旧内容与浏览位置，新结果到达后整体替换
        //（今日卡/列表闪空、翻页被重置的问题来自这里的旧清空逻辑）。
        failed = false
        refreshID += 1
    }

    private func reload() async {
        do {
            let value = try await service.review()
            try Task.checkCancellation()
            result = value
            // v3 选题：队列空时补一张（服务端模型文案，失败自动降级本机规则）。
            await DiscoveryTopicService.refreshIfNeeded(proposals: value.items.compactMap(\.proposal))
            try Task.checkCancellation()
            todayCard = DiscoveryTopicStore.shared.todayCard()
            if case .some(let items) = result.map({ $0.items.filter { item in
                guard let card = todayCard else { return true }
                return item.proposal?.propositionID != card.topicKey && item.proposal?.topicID != card.topicKey
            } }), !items.indices.contains(itemIndex) {
                itemIndex = 0
            }
        } catch is CancellationError {
            // 来源或页面切换后由新一轮读取接管。
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    // MARK: - 今日一条（v3 每日一卡）

    private func matchedItem(for card: DiscoveryTopicStore.QueuedCard) -> DiscoveryMemoryReviewService.Item? {
        result?.items.first {
            $0.proposal?.propositionID == card.topicKey || $0.proposal?.topicID == card.topicKey
        }
    }

    @ViewBuilder
    private func todayCardSection(_ card: DiscoveryTopicStore.QueuedCard) -> some View {
        // 与列表卡共用同一套骨架：holoSurface 白卡 + 主按钮整行 + 次按钮半行
        //（设计检查 #1/#3/#4：三键横排在 375pt 及以下必折行；旧米色底与徽标/按钮撞色）。
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.xs) {
                Text("今日一条")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolAction)
                if card.isModelCopy {
                    // 合规披露口径：标明这条文案由 AI 撰写（本机模板文案不标，诚实且不暴露降级）。
                    Text("AI 撰写")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolAction)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, HoloSpacing.xs)
                        .lineLimit(1)
                        .background(Color.holoToolAction.opacity(0.1), in: Capsule())
                }
            }
            Text(card.title)
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.body)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            if let item = matchedItem(for: card),
               let evidence = item.knowledge.latestEvidenceSnapshot ?? item.proposal?.initialEvidenceSnapshot {
                DiscoveryEvidenceToggle(showsEvidence: $showsTodayEvidence)
                    .accessibilityIdentifier("chat.discovery.today.evidence")
                if showsTodayEvidence {
                    DiscoveryReviewEvidence(evidence: evidence)
                }
            }
            DiscoveryDecisionControls(
                elevated: true,
                isDisabled: actionTask != nil || result == nil,
                idPrefix: "chat.discovery.today",
                onConfirm: { applyToday(.confirm, card: card) },
                onInaccurate: { applyToday(.markInaccurate(reason: nil, scope: .understanding), card: card) },
                onDefer: { applyToday(.deferCooldown, card: card) }
            )
        }
        .padding(HoloSpacing.md)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.today.card")
    }

    private func applyToday(_ action: HoloKnowledgeControlAction, card: DiscoveryTopicStore.QueuedCard) {
        guard actionTask == nil else { return }
        // 三键统一走知识事务（与列表卡同一 apply，动作互通）；今日卡消费与命题记忆
        // 在成功后落。提案已变（matchedItem 为 nil）时退化为仅本机标记。
        guard let item = matchedItem(for: card) else {
            DiscoveryTopicStore.shared.consumeToday()
            actionNotice = String(localized: "这条规律或它的依据有变化，请核对更新后的内容。")
            todayCard = nil
            return
        }
        actionNotice = nil
        actionTask = Task {
            defer { actionTask = nil }
            do {
                let outcome = try await service.apply(action, to: item)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .applied, .alreadyApplied:
                    let store = DiscoveryTopicStore.shared
                    switch action {
                    case .markInaccurate: store.markRejected(card.topicKey)
                    case .deferCooldown: store.markDeferred(card.topicKey)
                    default: break
                    }
                    store.consumeToday()
                    switch action {
                    case .confirm: actionNotice = String(localized: "已记住，可以在记忆中心查看。")
                    case .markInaccurate: actionNotice = String(localized: "已标记不准确。")
                    default: actionNotice = String(localized: "已暂缓提示这条规律。")
                    }
                    todayCard = nil
                case .notAllowed, .notFound, .conflict:
                    actionNotice = String(localized: "这条规律或它的依据有变化，请核对更新后的内容。")
                case .persistenceFailed:
                    actionNotice = String(localized: "这次没保存成功，可以再试一次。")
                }
            } catch is CancellationError {
                return
            } catch {
                actionNotice = String(localized: "这次没保存成功，可以再试一次。")
            }
        }
    }

    private func apply(_ action: HoloKnowledgeControlAction, to item: DiscoveryMemoryReviewService.Item) {
        guard actionTask == nil else { return }
        actionNotice = nil
        actionTask = Task {
            defer { actionTask = nil }
            do {
                let outcome = try await service.apply(action, to: item)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .applied, .alreadyApplied:
                    switch action {
                    case .confirm: actionNotice = String(localized: "已记住，可以在记忆中心查看。")
                    case .markInaccurate: actionNotice = String(localized: "已标记不准确。")
                    default: actionNotice = String(localized: "已暂缓提示这条规律。")
                    }
                    requestRefresh()
                case .notAllowed, .notFound, .conflict:
                    actionNotice = String(localized: "这条规律或它的依据有变化，请核对更新后的内容。")
                    requestRefresh()
                case .persistenceFailed:
                    actionNotice = String(localized: "这次没保存成功，可以再试一次。")
                }
            } catch is CancellationError {
                return
            } catch {
                actionNotice = String(localized: "这次没保存成功，可以再试一次。")
            }
        }
    }
}

private struct DiscoveryReviewCard: View {
    let knowledge: HoloResolvedKnowledge
    @Binding var showsEvidence: Bool
    let isApplying: Bool
    var elevatesPrimary: Bool
    let onAction: (HoloKnowledgeControlAction) -> Void

    init(knowledge: HoloResolvedKnowledge, showsEvidence: Binding<Bool>, isApplying: Bool,
         elevatesPrimary: Bool = true, onAction: @escaping (HoloKnowledgeControlAction) -> Void) {
        self.knowledge = knowledge
        self._showsEvidence = showsEvidence
        self.isApplying = isApplying
        self.elevatesPrimary = elevatesPrimary
        self.onAction = onAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(knowledge.domains.map(HoloMemoryCenterViewModel.domainTitle).joined(separator: " · "))
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolAction)
            Text(knowledge.displayText)
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.discovery.review.pattern")
            if let evidence = knowledge.latestEvidenceSnapshot {
                DiscoveryEvidenceToggle(showsEvidence: $showsEvidence)
                    .accessibilityIdentifier("chat.discovery.review.evidenceToggle")
                if showsEvidence { DiscoveryReviewEvidence(evidence: evidence) }
            }
            DiscoveryDecisionControls(
                elevated: elevatesPrimary,
                isDisabled: isApplying,
                idPrefix: "chat.discovery.review",
                onConfirm: { onAction(.confirm) },
                onInaccurate: { onAction(.markInaccurate(reason: nil, scope: .understanding)) },
                onDefer: { onAction(.deferCooldown) }
            )
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}

/// 依据入口：灰色文字链（不再是按钮样式，避免与三个决定并列成第四个选项）。
private struct DiscoveryEvidenceToggle: View {
    @Binding var showsEvidence: Bool

    var body: some View {
        Button {
            withAnimation(HoloAnimation.quick) { showsEvidence.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(showsEvidence ? "收起依据" : "查看依据")
                Image(systemName: showsEvidence ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 决定区共用组件（今日卡与列表卡同一份，防两处走样）：
/// 主按钮撑满整行（elevated=false 时降为描边，保证一屏一个橙色主操作）；
/// 两个次按钮等宽半行；大字号下自动改竖排（§8.1 修正：样式组件只包文字宽度，
/// 需在 label 上显式撑满——2026-11-08 设计检查 P0 实锤的根因）。
private struct DiscoveryDecisionControls: View {
    var elevated: Bool
    var isDisabled: Bool
    var idPrefix: String
    var onConfirm: () -> Void
    var onInaccurate: () -> Void
    var onDefer: () -> Void

    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button(action: onConfirm) {
                Text("对，记住")
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
            }
            .buttonStyle(HoloActionStyle(role: elevated ? .primary : .secondary))
            .accessibilityIdentifier("\(idPrefix).confirm")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HoloSpacing.sm) { secondaryRow }
                VStack(spacing: HoloSpacing.sm) { secondaryColumn }
            }
        }
        .disabled(isDisabled)
    }

    @ViewBuilder private var secondaryRow: some View {
        Button(action: onInaccurate) {
            Text("不太准确").frame(maxWidth: .infinity).lineLimit(1)
        }
        .accessibilityIdentifier("\(idPrefix).inaccurate")
        Button(action: onDefer) {
            Text("先放一放").frame(maxWidth: .infinity).lineLimit(1)
        }
        .accessibilityIdentifier("\(idPrefix).defer")
    }

    @ViewBuilder private var secondaryColumn: some View {
        Button(action: onInaccurate) {
            Text("不太准确").frame(maxWidth: .infinity).lineLimit(1)
        }
        .accessibilityIdentifier("\(idPrefix).inaccurate")
        Button(action: onDefer) {
            Text("先放一放").frame(maxWidth: .infinity).lineLimit(1)
        }
        .accessibilityIdentifier("\(idPrefix).defer")
    }
}

private struct DiscoveryReviewEvidence: View {
    let evidence: HoloKnowledgeEvidenceSnapshot

    /// 用户能看懂的日期：11/03 周二（§8.8 列表日期口径 M/d + 星期辅助定位）。
    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            if let from = evidence.observationWindowFrom, let to = evidence.observationWindowTo {
                let end = evidence.templateID == HoloKnowledgeTemplateID.boundedRecurrence.rawValue
                    ? to.addingTimeInterval(-1) : to
                Text("\(dayText(from)) – \(dayText(end))")
                    .holoText(.supporting)
            }
            if let summary = evidence.statsSummary {
                Text(summary).holoText(.metadata)
            }
            // 明细行：每条原始记录一行（日期 + 内容摘要，如「晚餐 ¥32」/「步数」）。
            ForEach(evidence.supportRefs + evidence.counterRefs) { ref in
                HStack(alignment: .firstTextBaseline) {
                    Text(dayText(ref.observedAt))
                        .lineLimit(1)
                    Spacer(minLength: HoloSpacing.sm)
                    Text(ref.summary ?? HoloMemoryCenterViewModel.domainTitle(ref.sourceDomain))
                        .multilineTextAlignment(.trailing)
                }
                .holoText(.metadata)
            }
        }
        .foregroundStyle(Color.holoToolTextSecondary)
        .padding(HoloSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        .accessibilityIdentifier("chat.discovery.review.evidence")
    }
}

