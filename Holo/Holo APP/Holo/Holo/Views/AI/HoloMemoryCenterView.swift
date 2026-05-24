//
//  HoloMemoryCenterView.swift
//  Holo
//
//  长期记忆管理中心：查看已确认记忆、处理候选、删除
//

import SwiftUI

struct HoloMemoryCenterView: View {

    @State private var confirmedMemories: [HoloLongTermMemory] = []
    @State private var candidates: [HoloLongTermMemory] = []
    @State private var selectedMemory: HoloLongTermMemory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
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

            Section {
                if confirmedMemories.isEmpty {
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
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadMemories() }
        .sheet(item: $selectedMemory) { memory in
            memoryDetailSheet(memory)
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
                Image(systemName: iconForType(memory.type))
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
                    LabeledContent("类型", value: typeLabel(memory.type))
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

                Section {
                    Button(role: .destructive) {
                        deleteMemory(memory)
                        dismiss()
                    } label: {
                        Label("删除这条记忆", systemImage: "trash")
                    }
                }
            }
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
        candidates = HoloLongTermMemoryStore.queryCandidates()
        confirmedMemories = HoloLongTermMemoryStore.queryConfirmed()
    }

    private func confirmCandidate(_ candidate: HoloLongTermMemory) {
        HoloLongTermMemoryStore.confirm(id: candidate.id)
        loadMemories()
    }

    private func rejectCandidate(_ candidate: HoloLongTermMemory) {
        HoloLongTermMemoryStore.reject(id: candidate.id)
        loadMemories()
    }

    private func deleteMemory(_ memory: HoloLongTermMemory) {
        HoloLongTermMemoryStore.delete(id: memory.id)
        loadMemories()
    }

    // MARK: - Helpers

    private func iconForType(_ type: HoloLongTermMemoryType) -> String {
        switch type {
        case .explicitUserPreference: return "hand.thumbsup"
        case .stableFeedbackPreference: return "chart.bar"
        case .recurringPattern: return "arrow.triangle.2.circlepath"
        case .longTermGoal: return "target"
        case .profileBackedFact: return "person.text.rectangle"
        }
    }

    private func typeLabel(_ type: HoloLongTermMemoryType) -> String {
        switch type {
        case .explicitUserPreference: return "明确偏好"
        case .stableFeedbackPreference: return "反馈偏好"
        case .recurringPattern: return "重复模式"
        case .longTermGoal: return "长期目标"
        case .profileBackedFact: return "档案事实"
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
}
