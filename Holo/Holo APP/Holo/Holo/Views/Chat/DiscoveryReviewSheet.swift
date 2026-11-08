import SwiftUI
import Combine

struct DiscoverySheetContent: View {
    @ObservedObject var viewModel: ChatViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        // v3：旧「服务端发布发现卡」阅读面板已退役，统一进入本机规律评审页。
        DiscoveryReviewSheet(
            showsEarlierFinding: viewModel.discoveryService.currentFinding != nil,
            onOpenEarlierFinding: { viewModel.openEarlierDiscoveryFinding() },
            onClose: { viewModel.closeDiscoveryDetail() }
        )
    }
}

struct DiscoveryReviewSheet: View {
    let showsEarlierFinding: Bool
    let onOpenEarlierFinding: () -> Void
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @AppStorage(DiscoverySettings.localFinanceKey) private var includesFinance = false
    @AppStorage(DiscoverySettings.localHealthKey) private var includesHealth = false
    @State private var result: DiscoveryMemoryReviewService.Result?
    @State private var refreshID = 0
    @State private var itemIndex = 0
    @State private var failed = false
    @State private var actionNotice: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var showsEvidence = false

    private let service = DiscoveryMemoryReviewService()

    var body: some View {
        HoloSheetScaffold(title: "一个发现", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    intro
                    if consent.isGranted && !service.domains.isEmpty {
                        reviewContent
                        sources
                        if showsEarlierFinding {
                            Button("查看另一条记录观察", action: onOpenEarlierFinding)
                                .buttonStyle(HoloActionStyle(role: .secondary))
                        }
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
        .onChange(of: includesFinance) { _, _ in requestRefresh() }
        .onChange(of: includesHealth) { _, _ in requestRefresh() }
        .onChange(of: consent.isGranted) { _, _ in requestRefresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { requestRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoDiscoverySettingsDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            if includesFinance { requestRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in requestRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .holoKnowledgeControlDidApply)) { _ in
            if actionTask == nil { requestRefresh() }
        }
        .onDisappear { actionTask?.cancel() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(Color.holoToolAction)
                .accessibilityHidden(true)
            Text("记录里，藏着一些规律")
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)
            Text("Holo 找到反复出现的记录时，会请你核对一次。你可以先看看依据。")
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
            if result.items.indices.contains(itemIndex) {
                let item = result.items[itemIndex]
                DiscoveryReviewCard(
                    knowledge: item.knowledge, showsEvidence: $showsEvidence,
                    isApplying: actionTask != nil, onAction: { apply($0, to: item) }
                )
                if result.items.count > 1 {
                    Button {
                        showsEvidence = false
                        itemIndex = (itemIndex + 1) % result.items.count
                    } label: {
                        Text("看下一条 · \(itemIndex + 1) / \(result.items.count)")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.holoToolAction)
                    .disabled(actionTask != nil)
                    .accessibilityIdentifier("chat.discovery.review.next")
                }
            } else {
                HoloInlineState(kind: .empty, message: "整理完成，暂时没有可以请你确认的规律。")
                    .accessibilityIdentifier("chat.discovery.review.empty")
            }
            Text("上次整理 · \(result.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
            if let notice = result.healthNotice {
                healthNotice(notice)
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        } else if failed {
            HoloInlineState(kind: .failure, message: "这次没有读完记录，可以重新整理。")
                .accessibilityIdentifier("chat.discovery.review.error")
        } else {
            HoloInlineState(kind: .loading, message: "正在核对你允许的记录…")
                .accessibilityIdentifier("chat.discovery.review.loading")
        }
        if result != nil || failed {
            Button("重新整理") { requestRefresh() }
                .buttonStyle(HoloActionStyle(role: .secondary))
                .disabled(actionTask != nil)
                .accessibilityIdentifier("chat.discovery.review.refresh")
        }
    }

    private func healthNotice(_ notice: DiscoveryMemoryReviewService.HealthNotice) -> Text {
        switch notice {
        case .noReadings: Text("有些健康记录未读到。可到「健康」检查步数、睡眠记录与读取权限。")
        case .waitingForUnlock: Text("部分健康记录需要解锁设备后读取。解锁后可重新整理。")
        case .unavailable: Text("部分健康记录暂时无法读取，可以重新整理。")
        }
    }

    private var sources: some View {
        DiscoveryReviewSourceControls(includesFinance: $includesFinance, includesHealth: $includesHealth)
            .disabled(actionTask != nil)
    }

    private func requestRefresh() {
        result = nil
        failed = false
        showsEvidence = false
        itemIndex = 0
        refreshID += 1
    }

    private func reload() async {
        do {
            let value = try await service.review()
            try Task.checkCancellation()
            result = value
        } catch is CancellationError {
            // 来源或页面切换后由新一轮读取接管。
        } catch {
            if !Task.isCancelled { failed = true }
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
    let onAction: (HoloKnowledgeControlAction) -> Void

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
                Button(showsEvidence ? "收起依据" : "查看依据") { showsEvidence.toggle() }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .accessibilityIdentifier("chat.discovery.review.evidenceToggle")
                if showsEvidence { DiscoveryReviewEvidence(evidence: evidence) }
            }
            VStack(spacing: HoloSpacing.xs) {
                Button("对，记住") { onAction(.confirm) }
                    .buttonStyle(HoloActionStyle(role: .primary))
                    .accessibilityIdentifier("chat.discovery.review.confirm")
                HStack {
                    Button("不太准确") { onAction(.markInaccurate(reason: nil, scope: .understanding)) }
                        .accessibilityIdentifier("chat.discovery.review.inaccurate")
                    Spacer(minLength: HoloSpacing.sm)
                    Button("先放一放") { onAction(.deferCooldown) }
                        .accessibilityIdentifier("chat.discovery.review.defer")
                }
                .buttonStyle(HoloActionStyle(role: .secondary))
            }
            .disabled(isApplying)
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}

private struct DiscoveryReviewEvidence: View {
    let evidence: HoloKnowledgeEvidenceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            if let from = evidence.observationWindowFrom, let to = evidence.observationWindowTo {
                let end = evidence.templateID == HoloKnowledgeTemplateID.boundedRecurrence.rawValue
                    ? to.addingTimeInterval(-1) : to
                Text("\(from.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                    .holoText(.supporting)
            }
            if let summary = evidence.statsSummary {
                Text(summary).holoText(.metadata)
            }
            ForEach(evidence.supportRefs + evidence.counterRefs) { ref in
                HStack(alignment: .firstTextBaseline) {
                    Text(ref.observedAt.formatted(date: .abbreviated, time: .omitted))
                    Spacer(minLength: HoloSpacing.sm)
                    Text(ref.summary ?? HoloMemoryCenterViewModel.domainTitle(ref.sourceDomain))
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

struct DiscoveryReviewSourceControls: View {
    @Binding var includesFinance: Bool
    @Binding var includesHealth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("一起整理这些记录")
                .holoText(.body)
                .fontWeight(.semibold)
            Toggle("财务支出", isOn: $includesFinance)
                .accessibilityIdentifier("discovery.review.source.finance")
            Toggle("健康步数与睡眠", isOn: $includesHealth)
                .accessibilityIdentifier("discovery.review.source.health")
            Text("这两类规律在此设备整理。点「对，记住」才会保存为你确认过的记忆。")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .tint(.holoPrimary)
        .foregroundStyle(Color.holoToolText)
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}
