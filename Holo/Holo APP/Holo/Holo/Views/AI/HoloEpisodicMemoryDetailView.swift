//
//  HoloEpisodicMemoryDetailView.swift
//  Holo
//
//  情景记忆详情 Sheet：查看证据、命中历史、隐藏/删除/拒绝
//

import SwiftUI

struct HoloEpisodicMemoryDetailView: View {

    let memory: HoloEpisodicMemory
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                // 基本信息区
                Section {
                    LabeledContent("状态", value: stateLabel(memory.state))
                    LabeledContent("置信度", value: confidenceLabel(memory.confidence))
                    LabeledContent("敏感度", value: sensitivityLabel(memory.sensitivity))

                    if let reasoning = memory.reasoningSummary {
                        LabeledContent("观察原因", value: reasoning)
                    }
                } header: {
                    Text("基本信息")
                }

                // 证据列表
                if !memory.evidence.isEmpty {
                    Section {
                        ForEach(memory.evidence) { ev in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ev.excerpt)
                                    .font(.system(size: 14))
                                HStack {
                                    Text("来源：\(ev.source.displayName)")
                                    if let date = formattedDate(ev.observedAt) {
                                        Text(date)
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("证据（\(memory.evidence.count) 条）")
                    }
                }

                // 命中历史
                Section {
                    LabeledContent("命中次数", value: "\(memory.hitCount)")
                    if let lastHit = memory.lastHitAt {
                        LabeledContent("最近命中", value: formattedDate(lastHit) ?? "未知")
                    }
                    if let runID = memory.createdFromRunID {
                        LabeledContent("来源 Run", value: runID)
                    }
                    if !memory.semanticHitRunIDs.isEmpty {
                        LabeledContent("关联 Run 数", value: "\(memory.semanticHitRunIDs.count)")
                    }
                } header: {
                    Text("命中历史")
                }

                // 过期时间
                Section {
                    LabeledContent("创建时间", value: formattedDate(memory.createdAt) ?? "未知")
                    LabeledContent("过期时间", value: formattedDate(memory.expiresAt) ?? "未知")
                    LabeledContent("剩余天数", value: daysUntilExpiry(memory.expiresAt))
                } header: {
                    Text("时间")
                }

                // 操作
                Section {
                    Button {
                        hideMemory()
                    } label: {
                        Label("隐藏这条记忆", systemImage: "eye.slash")
                    }
                    .tint(.orange)

                    Button(role: .destructive) {
                        deleteMemory()
                    } label: {
                        Label("删除这条记忆", systemImage: "trash")
                    }

                    Button(role: .destructive) {
                        rejectMemory()
                    } label: {
                        Label("拒绝并抑制类似记忆", systemImage: "hand.raised")
                    }
                    .tint(.red)
                }
            }
            .navigationTitle(memory.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func hideMemory() {
        HoloEpisodicMemoryStore.shared.updateState(id: memory.id, to: .archived)
        onDismiss()
        dismiss()
    }

    private func deleteMemory() {
        HoloEpisodicMemoryStore.shared.delete(id: memory.id)
        onDismiss()
        dismiss()
    }

    private func rejectMemory() {
        HoloEpisodicMemoryStore.shared.reject(id: memory.id)
        onDismiss()
        dismiss()
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func daysUntilExpiry(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 0 { return "已过期" }
        return "\(days) 天"
    }

    private func stateLabel(_ state: HoloEpisodicMemoryState) -> String {
        switch state {
        case .observing: return "观察中"
        case .active: return "活跃"
        case .suggested: return "建议"
        case .promotionCandidate: return "提升候选"
        case .promoted: return "已提升"
        case .rejected: return "已拒绝"
        case .expired: return "已过期"
        case .archived: return "已隐藏"
        }
    }

    private func confidenceLabel(_ confidence: HoloMemoryConfidence) -> String {
        switch confidence {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private func sensitivityLabel(_ sensitivity: HoloMemorySensitivity) -> String {
        switch sensitivity {
        case .normal: return "普通"
        case .highImpact: return "高影响"
        case .sensitive: return "敏感"
        }
    }
}
