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
    @State private var forceRefresh = false

    private let service = DiscoveryMemoryReviewService()

    struct Receipt: Equatable {
        enum Kind { case success, warning }
        var kind: Kind
        var text: String
    }

    var body: some View {
        HoloSheetScaffold(title: "一个发现", onClose: onClose) {
            // 03-I6：ScrollView 隐藏滚动条（设计规范；v4 卡上线时补齐，v3 同页受益）。
            ScrollView(showsIndicators: false) {
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
        .onAppear { HoloProductAnalytics.shared.track(.discoveryReviewOpened, ["source": "capsule"]) }
        .task(id: refreshID) {
            let force = forceRefresh
            forceRefresh = false
            await reload(force: force)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { requestRefresh(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoDiscoverySettingsDidChange)) { _ in requestRefresh(force: true) }
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
        let listedItems = result.items

        if let card = todayCard {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                DiscoverySectionHeader(
                    title: "今日一条",
                    trailing: Date().formatted(.dateTime.month().day().weekday(.wide))
                )
                DiscoveryInsightCardView(
                    card: card,
                    showsEvidence: $showsTodayEvidence,
                    isDisabled: actionTask != nil,
                    onConfirm: { applyV4Today(.confirm, card: card) },
                    onInaccurate: { applyV4Today(.inaccurate, card: card) },
                    onDefer: { applyV4Today(.defer, card: card) }
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
                DiscoverySectionHeader(
                    title: "等你确认",
                    count: listedItems.count,
                    trailing: result.checkedAt.formatted(.relative(presentation: .named))
                )
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
            // 预算墙（2026-11-21）：每周额度用完 → 升级引导卡（优先于普通空态展示）。
            if DiscoveryTopicStore.shared.isInsightQuotaWalledToday() {
                DiscoveryQuotaWallCard()
                    .padding(.top, HoloSpacing.xl)
            } else {
                // 空态：刚做完最后一个决定 →「看完了」；本来就没有 →「今天没有」。
                DiscoveryEmptyCard(
                    style: receipt != nil ? .doneToday : .noneToday,
                    onOpenMemory: { DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false)) }
                )
                .padding(.top, HoloSpacing.xl)
            }
        }
    }

    private func actionName(_ action: HoloKnowledgeControlAction) -> String {
        switch action {
        case .confirm: return "confirm"
        case .markInaccurate: return "inaccurate"
        case .deferCooldown: return "defer"
        default: return "other"
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

    private func requestRefresh(force: Bool = false) {
        // 刷新不闪屏：保留旧内容与浏览位置，新结果到达后整体替换。
        failed = false
        forceRefresh = forceRefresh || force
        refreshID += 1
    }

    private func reload(force: Bool = false) async {
        do {
            let value = try await service.review(ignoresCache: force)
            try Task.checkCancellation()
            result = value
            await DiscoveryInsightService.refreshIfNeeded(proposals: value.insightProposals)
            try Task.checkCancellation()
            todayCard = DiscoveryTopicStore.shared.todayCard()
            if let card = todayCard {
                HoloProductAnalytics.shared.track(.discoveryTodayShown, ["is_model_copy": card.isModelCopy ? "1" : "0"])
            }
            if let result, !result.items.indices.contains(itemIndex) {
                itemIndex = 0
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    // MARK: - 今日一条（v4 洞察卡：反馈走画像回流桥，不经知识控制流）

    private enum InsightAction { case confirm, inaccurate, `defer` }

    private func applyV4Today(_ action: InsightAction, card: DiscoveryTopicStore.QueuedCard) {
        guard actionTask == nil else { return }
        let actionLabel = action == .confirm ? "confirm" : (action == .inaccurate ? "inaccurate" : "defer")
        HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": actionLabel, "version": "4"])
        receipt = nil
        actionTask = Task {
            defer { actionTask = nil }
            let outcome: DiscoveryInsightFeedbackBridge.Outcome
            switch action {
            case .confirm:
                outcome = DiscoveryInsightFeedbackBridge.confirm(card: card)
            case .inaccurate:
                outcome = DiscoveryInsightFeedbackBridge.reject(card: card)
            case .`defer`:
                outcome = DiscoveryInsightFeedbackBridge.deferCard(card: card)
            }
            switch outcome {
            case .confirmedPortrait, .createdPortrait:
                receipt = Receipt(kind: .success, text: "已记住，可以在「Holo 记住的你」里找到。")
                HapticManager.success()
            case .rejected:
                receipt = Receipt(kind: .success, text: "这个角度近期不会再拿来问你。")
                HapticManager.light()
            case .deferred:
                receipt = Receipt(kind: .success, text: "先放着，这几天不再提这个角度。")
                HapticManager.light()
            case .unavailable:
                todayCard = DiscoveryTopicStore.shared.todayCard()
                receipt = Receipt(kind: .warning, text: "这条发现已更新，请再看一眼。")
                return
            case .persistenceFailed:
                receipt = Receipt(kind: .warning, text: "这次没保存成功，可以再试一次。")
                HapticManager.error()
                return
            }
            withAnimation(HoloAnimation.replayReveal) { todayCard = nil }
        }
    }

    private func apply(_ action: HoloKnowledgeControlAction, to item: DiscoveryMemoryReviewService.Item) {
        guard actionTask == nil else { return }
        HoloProductAnalytics.shared.track(.discoveryPendingAction, ["action": actionName(action)])
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
                    result?.items.removeAll { $0.id == item.id }
                    showsEvidence = false
                    if let result, !result.items.indices.contains(itemIndex) { itemIndex = 0 }
                    requestRefresh(force: true)
                case .notAllowed, .notFound, .conflict:
                    receipt = Receipt(kind: .warning, text: "这条规律的依据刚有变化，已换成最新内容，请再看一眼。")
                    HapticManager.error()
                    requestRefresh(force: true)
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
            if let evidence = item.knowledge.latestEvidenceSnapshot {
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

struct DiscoveryDecisionControls: View {
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
