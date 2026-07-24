//
//  DomainMemorySection.swift
//  Holo
//
//  记忆长廊里的用户可理解记忆中心。
//

import SwiftUI

enum HoloMemoryDisplayGroup: String, CaseIterable, Identifiable {
    case profile
    case finance
    case thought
    case health
    case habit
    case task
    case goal
    case conversation
    case crossDomain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "关于你"
        case .finance: return "财务"
        case .thought: return "观点"
        case .health: return "健康"
        case .habit: return "习惯"
        case .task: return "任务"
        case .goal: return "目标"
        case .conversation: return "对话"
        case .crossDomain: return "综合观察"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .finance: return "wallet.bifold"
        case .thought: return "quote.bubble"
        case .health: return "heart"
        case .habit: return "repeat"
        case .task: return "checkmark.circle"
        case .goal: return "flag"
        case .conversation: return "bubble.left.and.bubble.right"
        case .crossDomain: return "point.3.connected.trianglepath.dotted"
        }
    }

    static func group(for record: HoloMemoryRecord) -> HoloMemoryDisplayGroup? {
        if record.scope == .crossDomain { return .crossDomain }
        switch record.primaryDomain {
        case .profile: return .profile
        case .finance: return .finance
        case .thought: return .thought
        case .health: return .health
        case .habit: return .habit
        case .task: return .task
        case .goal: return .goal
        case .conversation: return .conversation
        case nil: return nil
        }
    }
}

extension HoloMemoryDomain {
    var userFacingName: String {
        switch self {
        case .finance: return "财务"
        case .thought: return "观点"
        case .health: return "健康"
        case .habit: return "习惯"
        case .task: return "任务"
        case .goal: return "目标"
        case .conversation: return "对话"
        case .profile: return "个人信息"
        }
    }
}

struct DomainMemorySection: View {
    @State private var records: [HoloMemoryRecord] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedRecord: HoloMemoryRecord?
    @State private var newMemoryIDs: Set<String> = []
    @State private var inboxSnapshot = HoloMemoryInboxSnapshot(
        newMemoryCount: 0,
        pendingConfirmationCount: 0,
        hasUnreadMigrationSummary: false
    )
    @State private var showsInboxSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header

            if showsInboxSummary, !inboxSnapshot.isEmpty {
                inboxSummaryCard
            }

            if isLoading {
                loadingCard
            } else if let loadError {
                failureCard(loadError)
            } else if records.isEmpty {
                emptyCard
            } else {
                if !pendingRecords.isEmpty {
                    specialMemoryGroup(
                        title: "想和你确认的",
                        icon: "questionmark.bubble",
                        records: pendingRecords
                    )
                }
                ForEach(nonemptyGroups) { group in
                    memoryGroup(group)
                }
                if !archivedRecords.isEmpty {
                    specialMemoryGroup(
                        title: "过去记忆",
                        icon: "archivebox",
                        records: archivedRecords
                    )
                }
            }
        }
        .task { await load() }
        .sheet(item: $selectedRecord) { record in
            NavigationStack {
                HoloMemoryRecordDetailView(record: record) { change in
                    apply(change)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text("Holo 的观察与记忆")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }

            Text("每条都标明会记多久：近期观察会随数据变化淡出，长期记忆只保留跨周期规律或你确认的重要事实。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var nonemptyGroups: [HoloMemoryDisplayGroup] {
        HoloMemoryDisplayGroup.allCases.filter { group in
            currentRecords.contains { HoloMemoryDisplayGroup.group(for: $0) == group }
        }
    }

    private var pendingRecords: [HoloMemoryRecord] {
        records.filter { $0.state == .candidate }
    }

    private var archivedRecords: [HoloMemoryRecord] {
        records.filter { $0.state == .archived }
    }

    private var currentRecords: [HoloMemoryRecord] {
        records.filter { $0.state != .candidate && $0.state != .archived }
    }

    private func memoryGroup(_ group: HoloMemoryDisplayGroup) -> some View {
        let groupRecords = currentRecords.filter { HoloMemoryDisplayGroup.group(for: $0) == group }
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: group.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text(group.title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text("\(groupRecords.count) 条")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            ForEach(groupRecords) { record in
                memoryCard(record)
            }
        }
    }

    private func specialMemoryGroup(
        title: String,
        icon: String,
        records: [HoloMemoryRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text(title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text("\(records.count) 条")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
            ForEach(records) { record in
                memoryCard(record)
            }
        }
    }

    private func memoryCard(_ record: HoloMemoryRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Text(record.displaySummary)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        if record.state == .candidate {
                            compactStatusBadge("待确认", icon: "questionmark", color: .orange)
                        } else if newMemoryIDs.contains(record.id) {
                            compactStatusBadge("新", icon: "sparkles", color: .holoPrimary)
                        } else if record.state == .archived {
                            compactStatusBadge("过去", icon: "archivebox", color: .holoTextSecondary)
                        }
                        if let badge = HoloMemoryFeedbackBadge(decision: record.userDecision) {
                            HoloMemoryFeedbackBadgeView(badge: badge)
                        }
                    }
                }

                HStack(spacing: HoloSpacing.xs) {
                    Label(
                        HoloMemoryUserPresentation.durationTitle(for: record),
                        systemImage: HoloMemoryUserPresentation.durationIcon(for: record)
                    )
                    Text("·")
                    Text(HoloMemoryUserPresentation.timeRange(for: record))
                    Text("·")
                    Text(HoloMemoryUserPresentation.sourceSummary(for: record))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)

                if let status = HoloMemoryUserPresentation.degradedStatus(for: record) {
                    Label(status, systemImage: "exclamationmark.circle")
                        .font(.holoTinyLabel)
                        .foregroundColor(.orange)
                }
            }
            .padding(HoloSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func compactStatusBadge(
        _ title: String,
        icon: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
            .fixedSize()
    }

    private var inboxSummaryCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .foregroundColor(.holoPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(inboxSnapshot.summaryText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                Text("Holo 会默认使用普通记忆，需要确认的内容暂不会参与回答。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer(minLength: 0)
            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showsInboxSummary = false
                newMemoryIDs = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var loadingCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            ProgressView()
            Text("正在整理已经形成的记忆…")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var emptyCard: some View {
        Text("还没有形成稳定记忆。继续使用 Holo 后，这里会逐步出现真正有帮助的总结。")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label("记忆暂时没有完整加载", systemImage: "exclamationmark.triangle")
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
            Text(message)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Button("重新加载") { Task { await load() } }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let unread = HoloMemoryReceiptStore.unreadWriteReceipts()
            newMemoryIDs = Set(unread.filter {
                $0.adoptionKind == .automaticallyAdopted
            }.flatMap(\.memoryIDs))
            inboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
            showsInboxSummary = !inboxSnapshot.isEmpty
            records = try await repository.query(.all).filter(Self.isUserVisible)
            isLoading = false
        } catch {
            records = []
            loadError = "你原来的记录没有丢失，可以稍后重试。"
            isLoading = false
        }
    }

    private static func isUserVisible(_ record: HoloMemoryRecord) -> Bool {
        guard HoloMemoryUsefulnessPolicy.isEligible(record) else { return false }
        if record.userDecision == .rejected {
            return record.state == .suppressed
        }
        guard [.candidate, .active, .disputed, .invalidated, .archived].contains(record.state) else {
            return false
        }
        return ![.forgotten, .markedIrrelevant].contains(record.userDecision)
    }

    private func apply(_ change: HoloMemoryRecordDetailChange) {
        switch change {
        case .updated(let record):
            newMemoryIDs.remove(record.id)
            if Self.isUserVisible(record),
               let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.removeAll { $0.id == record.id }
            }
            selectedRecord = record
        case .removed(let id):
            newMemoryIDs.remove(id)
            records.removeAll { $0.id == id }
            selectedRecord = nil
        }
    }
}

enum HoloMemoryFeedbackBadge: Equatable {
    case accurate
    case inaccurate
    case corrected

    init?(decision: HoloMemoryUserDecision) {
        switch decision {
        case .confirmed: self = .accurate
        case .rejected: self = .inaccurate
        case .corrected: self = .corrected
        case .none, .markedIrrelevant, .forgotten: return nil
        }
    }

    var title: String {
        switch self {
        case .accurate: return "准确"
        case .inaccurate: return "不准确"
        case .corrected: return "已纠正"
        }
    }

    var icon: String {
        switch self {
        case .accurate: return "checkmark"
        case .inaccurate: return "xmark"
        case .corrected: return "pencil"
        }
    }

    var color: Color {
        switch self {
        case .accurate: return .holoSuccess
        case .inaccurate: return .orange
        case .corrected: return .holoPrimary
        }
    }
}

struct HoloMemoryFeedbackBadgeView: View {
    let badge: HoloMemoryFeedbackBadge

    var body: some View {
        Label(badge.title, systemImage: badge.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(badge.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(badge.color.opacity(0.1))
            .clipShape(Capsule())
            .fixedSize()
    }
}

enum HoloMemoryUserPresentation {
    static func durationTitle(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState: return "近期观察"
        case .phase: return "当前阶段"
        case .durable: return "长期规律"
        case .permanentFact: return "长期事实"
        }
    }

    static func durationIcon(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState: return "clock"
        case .phase: return "calendar"
        case .durable: return "repeat"
        case .permanentFact: return "bookmark.fill"
        }
    }

    static func durationExplanation(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState:
            return "只代表最近一段时间，后续记录变化后会较快淡出。"
        case .phase:
            return "代表你当前阶段的状态，通常会保留数周到数月。"
        case .durable:
            return "由多个周期重复支持，会在相关问题中长期作为背景。"
        case .permanentFact:
            return "这是明确的重要事实；除非你纠正或删除，否则会长期保留。"
        }
    }

    static func timeRange(for record: HoloMemoryRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        switch (record.validFrom, record.validTo) {
        case let (start?, end?):
            if Calendar.current.isDate(start, inSameDayAs: end) {
                return formatter.string(from: end)
            }
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        case let (start?, nil):
            return "从\(formatter.string(from: start))起"
        case let (nil, end?):
            return "截至\(formatter.string(from: end))"
        case (nil, nil):
            return "持续观察中"
        }
    }

    static func sourceSummary(for record: HoloMemoryRecord) -> String {
        let names = record.sourceDomains.map(\.userFacingName)
        if record.scope == .crossDomain {
            return "来自\(joined(names))的综合观察"
        }
        return "来自\(joined(names))记录"
    }

    static func degradedStatus(for record: HoloMemoryRecord) -> String? {
        if record.state == .candidate {
            return "确认前不会用于 HoloAI 回答"
        }
        if record.state == .archived {
            return "这条记忆已经成为过去，不再用于当前回答"
        }
        if record.state == .invalidated {
            return "来源已经变化，这条记忆已暂停使用"
        }
        if record.state == .disputed {
            return "新的记录与它不完全一致，Holo 正在重新确认"
        }
        if record.evidenceRefs.isEmpty {
            return "来源暂不可用，这条记忆不会用于回答"
        }
        if record.scope == .crossDomain && record.upstreamMemoryIDs.count < record.sourceDomains.count {
            return "部分来源暂不可用，结论仅供参考"
        }
        return nil
    }

    private static func joined(_ values: [String]) -> String {
        let unique = Array(Set(values)).sorted()
        if unique.isEmpty { return "你的" }
        if unique.count == 1 { return unique[0] }
        return unique.dropLast().joined(separator: "、") + "和" + unique.last!
    }
}
