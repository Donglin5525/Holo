import SwiftUI
import Combine

// 「一个发现」评审页（v3 · 2026-11-08 版式重设计，东林选型 iOS 分组调型）。
// 版式规格真源：设计代理 2026-11-08 交付稿——
// 一个主角（今日卡 22pt holoTitle2）/ iOS 分组节奏（组标题+卡片）/ 橙色只给主操作
//（一屏一个实心橙）/ 依据账本化（日期列右对齐+例外分节+超 5 行折叠）。

struct DiscoverySheetContent: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
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
    @State private var receipt: Receipt?
    @State private var actionTask: Task<Void, Never>?
    @State private var showsEvidence = false
    @State private var todayCard: DiscoveryTopicStore.QueuedCard?
    @State private var showsTodayEvidence = false

    private let service = DiscoveryMemoryReviewService()

    struct Receipt: Equatable {
        enum Kind { case success, warning }
        var kind: Kind
        var text: String
    }

    var body: some View {
        HoloSheetScaffold(title: "一个发现", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Holo 每天从你的记录里挑一件反复出现的事来问你，你确认了才会记住。")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, HoloSpacing.page)
                        .accessibilityIdentifier("chat.discovery.review.intro")

                    if !consent.isGranted || service.domains.isEmpty {
                        DiscoveryEmptyCard(style: .notEnabled, onOpenMemory: nil)
                            .padding(.horizontal, HoloSpacing.page)
                            .padding(.top, HoloSpacing.lg)
                    } else if let result {
                        loadedContent(result)
                    } else if failed {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            HoloInlineState(kind: .failure, message: "这次没读完你的记录。")
                                .accessibilityIdentifier("chat.discovery.review.error")
                            Button("再试一次") { requestRefresh() }
                                .buttonStyle(HoloActionStyle(role: .secondary))
                                .accessibilityIdentifier("chat.discovery.review.retry")
                        }
                        .padding(.horizontal, HoloSpacing.page)
                        .padding(.top, HoloSpacing.lg)
                    } else {
                        HoloInlineState(kind: .loading, message: "正在翻你最近的记录…")
                            .padding(.horizontal, HoloSpacing.page)
                            .padding(.top, HoloSpacing.lg)
                            .accessibilityIdentifier("chat.discovery.review.loading")
                    }

                    if let notice = result?.healthNotice {
                        healthNotice(notice)
                            .padding(.horizontal, HoloSpacing.page)
                            .padding(.top, HoloSpacing.lg)
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.large])
        .task(id: refreshID) { await reload() }
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

    // MARK: - 加载完成的内容（今日区 → 回执 → 列表区 → 空态）

    @ViewBuilder
    private func loadedContent(_ result: DiscoveryMemoryReviewService.Result) -> some View {
        let listedItems = result.items.filter { item in
            guard let card = todayCard else { return true }
            return item.proposal?.propositionID != card.topicKey && item.proposal?.topicID != card.topicKey
        }

        if let card = todayCard {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                DiscoverySectionHeader(
                    title: "今日一条",
                    trailing: Date().formatted(.dateTime.month().day().weekday(.wide))
                )
                DiscoveryTodayCard(
                    card: card,
                    evidence: matchedItem(for: card).flatMap { item in
                        item.knowledge.latestEvidenceSnapshot ?? item.proposal?.initialEvidenceSnapshot
                    },
                    showsEvidence: $showsTodayEvidence,
                    isDisabled: actionTask != nil,
                    onConfirm: { applyToday(.confirm, card: card) },
                    onInaccurate: { applyToday(.markInaccurate(reason: nil, scope: .understanding), card: card) },
                    onDefer: { applyToday(.deferCooldown, card: card) }
                )
            }
            .padding(.top, HoloSpacing.lg)
        }

        if let receipt {
            DiscoveryReceiptBanner(receipt: receipt)
                .padding(.top, HoloSpacing.xl)
        }

        if !listedItems.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                DiscoverySectionHeader(title: "等你确认", count: listedItems.count)
                if listedItems.indices.contains(itemIndex) {
                    let item = listedItems[itemIndex]
                    DiscoveryPendingCard(
                        item: item,
                        showsEvidence: $showsEvidence,
                        isDisabled: actionTask != nil,
                        elevatesPrimary: todayCard == nil,
                        onAction: { apply($0, to: item) }
                    )
                    .id(item.knowledge.propositionID)
                    .transition(.opacity)
                }
                if listedItems.count > 1 {
                    DiscoveryPagerRow(index: itemIndex, count: listedItems.count) {
                        withAnimation(HoloAnimation.replayReveal) {
                            showsEvidence = false
                            itemIndex = (itemIndex + 1) % listedItems.count
                        }
                    }
                }
            }
            .padding(.top, HoloSpacing.xl)
        } else if todayCard == nil {
            // 空态：刚做完最后一个决定 →「看完了」；本来就没有 →「今天没有」。
            DiscoveryEmptyCard(
                style: receipt != nil ? .doneToday : .noneToday,
                onOpenMemory: { DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false)) }
            )
            .padding(.top, HoloSpacing.xl)
        }
    }

    // MARK: - 健康提示

    private func healthNotice(_ notice: DiscoveryMemoryReviewService.HealthNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
            Image(systemName: "heart")
                .font(.footnote)
                .foregroundStyle(Color.holoToolTextSecondary)
            healthText(for: notice)
        }
        .accessibilityIdentifier("chat.discovery.review.health")
    }

    private func healthText(for notice: DiscoveryMemoryReviewService.HealthNotice) -> some View {
        Group {
            switch notice {
            case .noReadings:
                if HealthRepository.shared.hasRequestedPermission {
                    Text("最近没读到步数和睡眠，可以去 iPhone 自带的「健康」App 看看权限。")
                } else {
                    Text("连上健康数据，能多发现睡眠和步数的规律。")
                }
            case .waitingForUnlock:
                Text("有几条健康数据要等手机解锁才能读，解锁后这里会自动更新。")
            case .unavailable:
                Text("健康数据这次没读到，过会儿再打开看看。")
            }
        }
        .holoText(.metadata)
        .foregroundStyle(Color.holoToolTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 刷新与加载

    private func requestRefresh() {
        // 刷新不闪屏：保留旧内容与浏览位置，新结果到达后整体替换。
        failed = false
        refreshID += 1
    }

    private func reload() async {
        do {
            let value = try await service.review()
            try Task.checkCancellation()
            result = value
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

    private func applyToday(_ action: HoloKnowledgeControlAction, card: DiscoveryTopicStore.QueuedCard) {
        guard actionTask == nil else { return }
        guard let item = matchedItem(for: card) else {
            DiscoveryTopicStore.shared.consumeToday()
            withAnimation(HoloAnimation.replayReveal) { todayCard = nil }
            receipt = Receipt(kind: .warning, text: "这条规律的依据刚有变化，已换成最新内容，请再看一眼。")
            return
        }
        receipt = nil
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
                    case .confirm:
                        receipt = Receipt(kind: .success, text: "已记住，可以在「Holo 记忆」里找到。")
                        HapticManager.success()
                    case .markInaccurate:
                        receipt = Receipt(kind: .success, text: "这条以后不会再拿来问你。")
                        HapticManager.light()
                    default:
                        receipt = Receipt(kind: .success, text: "先放着，这几天不再问这条。")
                        HapticManager.light()
                    }
                    withAnimation(HoloAnimation.replayReveal) { todayCard = nil }
                case .notAllowed, .notFound, .conflict:
                    receipt = Receipt(kind: .warning, text: "这条规律的依据刚有变化，已换成最新内容，请再看一眼。")
                    HapticManager.error()
                case .persistenceFailed:
                    receipt = Receipt(kind: .warning, text: "这次没保存成功，可以再试一次。")
                    HapticManager.error()
                }
            } catch is CancellationError {
                return
            } catch {
                receipt = Receipt(kind: .warning, text: "这次没保存成功，可以再试一次。")
                HapticManager.error()
            }
        }
    }

    private func apply(_ action: HoloKnowledgeControlAction, to item: DiscoveryMemoryReviewService.Item) {
        guard actionTask == nil else { return }
        receipt = nil
        actionTask = Task {
            defer { actionTask = nil }
            do {
                let outcome = try await service.apply(action, to: item)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .applied, .alreadyApplied:
                    switch action {
                    case .confirm:
                        receipt = Receipt(kind: .success, text: "已记住，可以在「Holo 记忆」里找到。")
                        HapticManager.success()
                    case .markInaccurate:
                        receipt = Receipt(kind: .success, text: "这条以后不会再拿来问你。")
                        HapticManager.light()
                    default:
                        receipt = Receipt(kind: .success, text: "先放着，这几天不再问这条。")
                        HapticManager.light()
                    }
                    requestRefresh()
                case .notAllowed, .notFound, .conflict:
                    receipt = Receipt(kind: .warning, text: "这条规律的依据刚有变化，已换成最新内容，请再看一眼。")
                    HapticManager.error()
                    requestRefresh()
                case .persistenceFailed:
                    receipt = Receipt(kind: .warning, text: "这次没保存成功，可以再试一次。")
                    HapticManager.error()
                }
            } catch is CancellationError {
                return
            } catch {
                receipt = Receipt(kind: .warning, text: "这次没保存成功，可以再试一次。")
                HapticManager.error()
            }
        }
    }
}

// MARK: - 组标题（iOS 分组节奏：灰标题 + 计数徽章 + 右侧文字）

private struct DiscoverySectionHeader: View {
    let title: String
    var count: Int?
    var trailing: String?

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text(title)
                .holoText(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1)
            if let count {
                HoloCountBadge(count: count)
            }
            Spacer(minLength: HoloSpacing.sm)
            if let trailing {
                Text(trailing)
                    .holoText(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(count.map { "\(title)，共 \($0) 条" } ?? title))
    }
}

// MARK: - 今日卡（页面主角：22pt 标题）

private struct DiscoveryTodayCard: View {
    let card: DiscoveryTopicStore.QueuedCard
    var evidence: HoloKnowledgeEvidenceSnapshot?
    @Binding var showsEvidence: Bool
    let isDisabled: Bool
    let onConfirm: () -> Void
    let onInaccurate: () -> Void
    let onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            if card.isModelCopy {
                // 合规披露：标明文案由 AI 撰写（本机模板不标）。
                CardBadge(text: "AI 撰写", color: .holoToolTextSecondary)
            }
            Text(card.title)
                .font(.holoTitle2)
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(HoloSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.body)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(HoloSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)
            if let evidence {
                DiscoveryEvidenceToggle(showsEvidence: $showsEvidence, count: evidence.supportRefs.count + evidence.counterRefs.count)
                    .accessibilityIdentifier("chat.discovery.today.evidence")
                if showsEvidence {
                    DiscoveryReviewEvidence(evidence: evidence)
                }
            }
            DiscoveryDecisionControls(
                elevated: true,
                isDisabled: isDisabled,
                idPrefix: "chat.discovery.today",
                onConfirm: onConfirm,
                onInaccurate: onInaccurate,
                onDefer: onDefer
            )
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.today.card")
    }
}

// MARK: - 列表卡（配角：17pt 半粗陈述句）

private struct DiscoveryPendingCard: View {
    let item: DiscoveryMemoryReviewService.Item
    @Binding var showsEvidence: Bool
    let isDisabled: Bool
    let elevatesPrimary: Bool
    let onAction: (HoloKnowledgeControlAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(item.knowledge.domains.map(HoloMemoryCenterViewModel.domainTitle).joined(separator: " · "))
                .holoText(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1)
            Text(item.knowledge.displayText)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(HoloSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.discovery.review.pattern")
            if let evidence = item.knowledge.latestEvidenceSnapshot ?? item.proposal?.initialEvidenceSnapshot {
                DiscoveryEvidenceToggle(showsEvidence: $showsEvidence, count: evidence.supportRefs.count + evidence.counterRefs.count)
                    .accessibilityIdentifier("chat.discovery.review.evidenceToggle")
                if showsEvidence {
                    DiscoveryReviewEvidence(evidence: evidence)
                }
            }
            DiscoveryDecisionControls(
                elevated: elevatesPrimary,
                isDisabled: isDisabled,
                idPrefix: "chat.discovery.review",
                onConfirm: { onAction(.confirm) },
                onInaccurate: { onAction(.markInaccurate(reason: nil, scope: .understanding)) },
                onDefer: { onAction(.deferCooldown) }
            )
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
    }
}

// MARK: - 决定区（一行两键 + 文字按钮「先放一放」）

private struct DiscoveryDecisionControls: View {
    var elevated: Bool
    var isDisabled: Bool
    var idPrefix: String
    var onConfirm: () -> Void
    var onInaccurate: () -> Void
    var onDefer: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HoloSpacing.sm) { pair }
                VStack(spacing: HoloSpacing.sm) { pair }
            }
            Button(action: onDefer) {
                Text("先放一放")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .disabled(isDisabled)
            .padding(.bottom, HoloSpacing.sm)
        }
        .disabled(isDisabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var pair: some View {
        Button(action: onConfirm) {
            Text("对，记住").frame(maxWidth: .infinity).lineLimit(1)
        }
        .buttonStyle(HoloActionStyle(role: elevated ? .primary : .secondary))
        .accessibilityIdentifier("\(idPrefix).confirm")
        Button(action: onInaccurate) {
            Text("不太准确").frame(maxWidth: .infinity).lineLimit(1)
        }
        .buttonStyle(HoloActionStyle(role: .secondary))
        .accessibilityIdentifier("\(idPrefix).inaccurate")
    }
}

// MARK: - 依据开关（灰色文字链 + 条数，整行 44 可点）

private struct DiscoveryEvidenceToggle: View {
    @Binding var showsEvidence: Bool
    var count: Int

    private var label: String {
        let base = showsEvidence ? "收起依据" : "查看依据"
        return count > 0 ? "\(base) · \(count) 条记录" : base
    }

    var body: some View {
        Button {
            withAnimation(HoloAnimation.replayReveal) { showsEvidence.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Image(systemName: showsEvidence ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("依据"))
        .accessibilityValue(Text(showsEvidence ? "已展开" : "已收起"))
    }
}

// MARK: - 依据明细（账本式：日期列右对齐 + 星期列 + 内容列；例外分节；超 5 行折叠）

private struct DiscoveryReviewEvidence: View {
    let evidence: HoloKnowledgeEvidenceSnapshot
    @State private var showsAll = false

    /// 依据明细日期：M/d（如 11/3）——中文 locale 的 formatted 会输出「11月3日」
    /// 导致 34pt 日期列折行（东林真机实报 2026-11-08），必须手动拼。
    private func dayText(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
    private func weekdayText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    var body: some View {
        let supports = evidence.supportRefs
        let counters = evidence.counterRefs
        let total = supports.count + counters.count
        let visibleSupports = showsAll ? supports : Array(supports.prefix(5))
        return VStack(alignment: .leading, spacing: 4) {
            if let from = evidence.observationWindowFrom, let to = evidence.observationWindowTo {
                let end = evidence.templateID == HoloKnowledgeTemplateID.boundedRecurrence.rawValue
                    ? to.addingTimeInterval(-1) : to
                Text("\(dayText(from)) \(weekdayText(from)) – \(dayText(end)) \(weekdayText(end))")
                    .holoText(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .monospacedDigit()
            }
            if let summary = evidence.statsSummary {
                Text(summary)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolText)
            }
            if !visibleSupports.isEmpty {
                evidenceTable(visibleSupports, dimmed: false)
                    .padding(.top, HoloSpacing.md)
            }
            if total > 5 && !showsAll {
                Button {
                    withAnimation(HoloAnimation.replayReveal) { showsAll = true }
                } label: {
                    HStack(spacing: 4) {
                        Text("显示全部 \(total) 条")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !counters.isEmpty && (showsAll || supports.count <= 5) {
                Text("例外 · \(counters.count) 次")
                    .holoText(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.top, HoloSpacing.md)
                evidenceTable(counters, dimmed: true)
                    .padding(.top, HoloSpacing.sm)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("chat.discovery.review.evidence")
    }

    @ViewBuilder
    private func evidenceTable(_ refs: [HoloMemoryEvidenceRef], dimmed: Bool) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(refs) { ref in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // 两位数日（10/12）5 字符 ≈38pt：列宽 40 + 禁折行
                    //（东林真机实报 10/12 被断成「10/1」+孤行「2」；折行绝不允许，宁可截断）。
                    Text(dayText(ref.observedAt))
                        .holoText(.metadata)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 40, alignment: .trailing)
                    Text(weekdayText(ref.observedAt))
                        .holoText(.metadata)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 36, alignment: .leading)
                    Text(ref.summary ?? HoloMemoryCenterViewModel.domainTitle(ref.sourceDomain))
                        .holoText(.supporting)
                        .foregroundStyle(dimmed ? Color.holoToolTextSecondary : Color.holoToolText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
    }
}

// MARK: - 翻页行（1 / N + 看下一条›）

private struct DiscoveryPagerRow: View {
    let index: Int
    let count: Int
    let onNext: () -> Void

    var body: some View {
        Button(action: onNext) {
            HStack(spacing: HoloSpacing.sm) {
                Text("\(index + 1) / \(count)")
                    .holoText(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: HoloSpacing.sm)
                HStack(spacing: 4) {
                    Text("看下一条").font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.holoToolAction)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityLabel(Text("看下一条"))
        .accessibilityValue(Text("第 \(index + 1) 条，共 \(count) 条"))
        .accessibilityIdentifier("chat.discovery.review.next")
    }
}

// MARK: - 回执条（淡底状态条：成功绿 / 异常琥珀）

private struct DiscoveryReceiptBanner: View {
    let receipt: DiscoveryReviewSheet.Receipt

    private var tint: Color {
        receipt.kind == .success ? Color.holoToolSuccess : Color.holoToolWarning
    }

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: receipt.kind == .success ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.body)
            Text(receipt.text)
                .holoText(.supporting)
                .fontWeight(.medium)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.xs)
        .frame(minHeight: 44, alignment: .leading)
        .foregroundStyle(tint)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityIdentifier("chat.discovery.review.receipt")
    }
}

// MARK: - 空态卡（四件套左对齐：图标/标题/说明/动作）

private struct DiscoveryEmptyCard: View {
    enum Style {
        case noneToday, doneToday, notEnabled
    }

    let style: Style
    let onOpenMemory: (() -> Void)?

    private var icon: String {
        switch style {
        case .noneToday: return "text.magnifyingglass"
        case .doneToday: return "checkmark.circle"
        case .notEnabled: return "pause.circle"
        }
    }

    private var title: String {
        switch style {
        case .noneToday: return "今天没有新发现"
        case .doneToday: return "今天的都看完了"
        case .notEnabled: return "「一个发现」还没开启"
        }
    }

    private var subtitle: String {
        switch style {
        case .noneToday: return "同一件事在不同的日子反复出现，Holo 就会拿来问你一句。"
        case .doneToday: return "有新的规律时，Holo 会再来问你。"
        case .notEnabled: return "开启并允许使用记录后，Holo 会从里面找反复出现的事来问你。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 44, height: 44, alignment: .leading)
            Text(title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
            Text(subtitle)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, HoloSpacing.xs)
            if style != .notEnabled, let onOpenMemory {
                Button("看看已经记住的", action: onOpenMemory)
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .padding(.top, HoloSpacing.md)
                    .accessibilityIdentifier("chat.discovery.review.openMemory")
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityIdentifier("chat.discovery.review.empty")
    }
}
