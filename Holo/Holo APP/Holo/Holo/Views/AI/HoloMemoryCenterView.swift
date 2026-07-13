//
//  HoloMemoryCenterView.swift
//  Holo
//
//  记忆管理中心：情景记忆（短期）、长期候选、已确认长期记忆
//

import SwiftUI

struct HoloMemoryCenterView: View {

    @State private var episodicMemories: [HoloEpisodicMemory] = []
    @State private var confirmedMemories: [HoloLongTermMemory] = []
    @State private var candidates: [HoloLongTermMemory] = []
    @State private var receipts: [HoloMemoryReceipt] = []
    @State private var selectedMemory: HoloLongTermMemory?
    @State private var selectedEpisodic: HoloEpisodicMemory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // Section 1: 最近记住（情景记忆）
            if !episodicMemories.isEmpty {
                Section {
                    ForEach(episodicMemories) { memory in
                        episodicMemoryRow(memory)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteEpisodicMemory(memory)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    hideEpisodicMemory(memory)
                                } label: {
                                    Label("隐藏", systemImage: "eye.slash")
                                }
                                .tint(.orange)
                            }
                    }
                } header: {
                    HStack {
                        Image(systemName: "eye.circle")
                            .font(.system(size: 12))
                        Text("最近记住（\(episodicMemories.count)）")
                    }
                }
            }

            // Section 2: 待确认（长期候选）
            if !candidates.isEmpty {
                Section {
                    ForEach(candidates) { candidate in
                        HoloMemoryCandidateCard(
                            memory: candidate,
                            onConfirm: { confirmCandidate(candidate) },
                            onReject: { rejectCandidate(candidate) }
                        )
                    }
                } header: {
                    HStack {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12))
                        Text("待确认（\(candidates.count)）")
                    }
                }
            }

            if !receipts.isEmpty {
                Section {
                    ForEach(receipts.prefix(8)) { receipt in
                        memoryReceiptRow(receipt)
                    }
                } header: {
                    HStack {
                        Image(systemName: "checkmark.message")
                            .font(.system(size: 12))
                        Text("记忆动态")
                    }
                }
            }

            // Section 3: 已记住（已确认长期记忆）
            Section {
                if confirmedMemories.isEmpty && episodicMemories.isEmpty && candidates.isEmpty {
                    emptyStateView
                } else {
                    ForEach(confirmedMemories) { memory in
                        memoryRow(memory)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteMemory(memory)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                    Text("已记住（\(confirmedMemories.count)）")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadMemories() }
        .sheet(item: $selectedMemory) { memory in
            memoryDetailSheet(memory)
        }
        .sheet(item: $selectedEpisodic) { memory in
            HoloEpisodicMemoryDetailView(memory: memory, onDismiss: { loadMemories() })
        }
    }

    // MARK: - Episodic Memory Row

    private func episodicMemoryRow(_ memory: HoloEpisodicMemory) -> some View {
        Button {
            selectedEpisodic = memory
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconForSource(memory.sourceModules.first))
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Text(memory.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if !memory.evidence.isEmpty {
                            Label("\(memory.evidence.count) 条证据", systemImage: "doc.text")
                                .font(.system(size: 11))
                        }
                        Text("过期：\(daysUntilExpiry(memory.expiresAt))")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                Spacer()
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36))
                .foregroundColor(.holoTextSecondary)
            Text("Holo 还没有记住任何内容")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("随着你持续使用，Holo 会学习你的偏好和模式")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }

    // MARK: - Memory Row

    private func memoryRow(_ memory: HoloLongTermMemory) -> some View {
        Button {
            selectedMemory = memory
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconForSemanticType(memory.semanticType))
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(memory.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)

                        Text(semanticTypeDisplayName(memory.semanticType))
                            .font(.system(size: 10))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.holoPrimary.opacity(0.1))
                            .cornerRadius(3)
                    }

                    Text(memory.displaySummary)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }

                Spacer()

                if memory.confirmationState == .silentlyAccepted {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }

    // MARK: - Detail Sheet

    private func memoryDetailSheet(_ memory: HoloLongTermMemory) -> some View {
        NavigationView {
            List {
                Section {
                    LabeledContent("语义类型", value: semanticTypeDisplayName(memory.semanticType))
                    LabeledContent("确认状态", value: stateLabel(memory.confirmationState))
                    LabeledContent("置信度", value: confidenceLabel(memory.confidence))
                } header: {
                    Text("基本信息")
                }

                if !memory.evidence.isEmpty {
                    Section {
                        ForEach(memory.evidence) { ev in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ev.excerpt)
                                    .font(.system(size: 14))
                                Text("来源：\(ev.source.displayName)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("证据")
                    }
                }

                let memoryReceipts = HoloMemoryReceiptStore.receipts(for: memory.id)
                if !memoryReceipts.isEmpty {
                    Section {
                        ForEach(memoryReceipts.prefix(10)) { receipt in
                            memoryReceiptRow(receipt)
                        }
                    } header: {
                        Text("写入与使用记录")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        deleteMemory(memory)
                        dismiss()
                    } label: {
                        Label("删除这条记忆", systemImage: "trash")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .navigationTitle(memory.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadMemories() {
        episodicMemories = HoloEpisodicMemoryStore.shared.querySuggested()
        candidates = HoloLongTermMemoryStore.queryCandidates()
        confirmedMemories = HoloLongTermMemoryStore.queryConfirmed()
        receipts = HoloMemoryReceiptStore.load()
    }

    private func confirmCandidate(_ candidate: HoloLongTermMemory) {
        _ = HoloLongTermMemoryStore.confirm(id: candidate.id)
        loadMemories()
    }

    private func rejectCandidate(_ candidate: HoloLongTermMemory) {
        _ = HoloLongTermMemoryStore.reject(id: candidate.id)
        loadMemories()
    }

    private func deleteMemory(_ memory: HoloLongTermMemory) {
        _ = HoloLongTermMemoryStore.delete(id: memory.id)
        loadMemories()
    }

    private func deleteEpisodicMemory(_ memory: HoloEpisodicMemory) {
        HoloEpisodicMemoryStore.shared.delete(id: memory.id)
        loadMemories()
    }

    private func hideEpisodicMemory(_ memory: HoloEpisodicMemory) {
        HoloEpisodicMemoryStore.shared.updateState(id: memory.id, to: .archived)
        loadMemories()
    }

    // MARK: - Helpers

    private func daysUntilExpiry(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 0 { return "已过期" }
        return "\(days) 天后"
    }

    private func iconForSource(_ source: HoloMemorySource?) -> String {
        guard let source else { return "circle" }
        switch source {
        case .habits: return "flame"
        case .goals: return "target"
        case .finance: return "yensign.circle"
        case .health: return "heart"
        case .tasks: return "checklist"
        case .thoughts: return "lightbulb"
        case .profile: return "person"
        case .conversation: return "bubble.left"
        case .memoryInsight: return "sparkles"
        }
    }

    private func iconForSemanticType(_ type: HoloMemorySemanticType) -> String {
        switch type {
        case .phaseShift: return "arrow.triangle.2.circlepath"
        case .stablePattern: return "chart.bar"
        case .driftSignal: return "exclamationmark.arrow.triangle.2.circlepath"
        case .lifeEvent: return "person.text.rectangle"
        case .statMilestone: return "flag.checkered"
        }
    }

    private func stateLabel(_ state: HoloMemoryConfirmationState) -> String {
        switch state {
        case .candidate: return "候选"
        case .silentlyAccepted: return "已静默接受"
        case .confirmed: return "已确认"
        case .rejected: return "已拒绝"
        case .archived: return "已归档"
        }
    }

    private func confidenceLabel(_ confidence: HoloMemoryConfidence) -> String {
        switch confidence {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private func semanticTypeDisplayName(_ type: HoloMemorySemanticType) -> String {
        switch type {
        case .phaseShift: return "阶段变化"
        case .stablePattern: return "稳定习惯"
        case .driftSignal: return "偏离提醒"
        case .lifeEvent: return "人生节点"
        case .statMilestone: return "轻量记录"
        }
    }

    private func memoryReceiptRow(_ receipt: HoloMemoryReceipt) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: receipt.kind == .write ? "brain.head.profile.fill" : "quote.bubble.fill")
                .foregroundColor(receipt.kind == .write ? .holoPrimary : .blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.message)
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextPrimary)
                Text("\(receiptChannelLabel(receipt.channel)) · \(receiptDateLabel(receipt.createdAt))")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func receiptChannelLabel(_ channel: HoloMemoryReceiptChannel) -> String {
        switch channel {
        case .insight: return "洞察"
        case .chat: return "对话"
        case .analysis: return "深度分析"
        case .agent: return "Agent"
        }
    }

    private func receiptDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
