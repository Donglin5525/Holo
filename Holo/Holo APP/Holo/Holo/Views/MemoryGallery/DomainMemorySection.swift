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

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header

            if isLoading {
                loadingCard
            } else if let loadError {
                failureCard(loadError)
            } else if records.isEmpty {
                emptyCard
            } else {
                ForEach(nonemptyGroups) { group in
                    memoryGroup(group)
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

                Text("Holo 记住的你")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }

            Text("这些内容会在合适的问题里自动帮上忙，你可以随时评价、纠正或删除。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var nonemptyGroups: [HoloMemoryDisplayGroup] {
        HoloMemoryDisplayGroup.allCases.filter { group in
            records.contains { HoloMemoryDisplayGroup.group(for: $0) == group }
        }
    }

    private func memoryGroup(_ group: HoloMemoryDisplayGroup) -> some View {
        let groupRecords = records.filter { HoloMemoryDisplayGroup.group(for: $0) == group }
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

                    if let badge = HoloMemoryFeedbackBadge(decision: record.userDecision) {
                        HoloMemoryFeedbackBadgeView(badge: badge)
                    }
                }

                HStack(spacing: HoloSpacing.xs) {
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
            records = try await repository.query(.all).filter(Self.isUserVisible)
            isLoading = false
        } catch {
            records = []
            loadError = "你原来的记录没有丢失，可以稍后重试。"
            isLoading = false
        }
    }

    private static func isUserVisible(_ record: HoloMemoryRecord) -> Bool {
        if record.userDecision == .rejected {
            return record.state == .suppressed
        }
        guard [.active, .disputed, .invalidated].contains(record.state) else { return false }
        return ![.forgotten, .markedIrrelevant].contains(record.userDecision)
    }

    private func apply(_ change: HoloMemoryRecordDetailChange) {
        switch change {
        case .updated(let record):
            if Self.isUserVisible(record),
               let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.removeAll { $0.id == record.id }
            }
            selectedRecord = record
        case .removed(let id):
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
