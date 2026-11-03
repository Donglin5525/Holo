//
//  HoloMemoryCandidateCard.swift
//  Holo
//
//  长期记忆候选卡片：确认/拒绝/查看证据
//

import SwiftUI

struct HoloMemoryCandidateCard: View {

    let memory: HoloLongTermMemory
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Image(systemName: "lightbulb")
                    .holoText(.supporting)
                    .foregroundColor(.holoPrimary)
                Text(memory.title)
                    .holoText(.supporting)
                    .fontWeight(.medium)
                    .foregroundColor(.holoToolText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HoloSpacing.sm) {
                    semanticTypeBadge(memory.semanticType)
                    if memory.sensitivity != .normal { sensitivityBadge }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    semanticTypeBadge(memory.semanticType)
                    if memory.sensitivity != .normal { sensitivityBadge }
                }
            }

            Text(memory.displaySummary)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !memory.evidence.isEmpty {
                evidencePreview
            }

            HStack(spacing: 12) {
                Button {
                    onReject()
                } label: {
                    Text("忽略")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoloActionStyle(role: .secondary))

                Button {
                    onConfirm()
                } label: {
                    Text("记住")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoloActionStyle(role: .primary))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sensitivity Badge

    private var sensitivityBadge: some View {
        Text(memory.sensitivity == .sensitive ? String(localized: "敏感") : String(localized: "高影响"))
            .holoText(.metadata)
            .foregroundColor(.holoToolWarning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.holoToolWarning.opacity(0.1))
            .cornerRadius(4)
    }

    // MARK: - Semantic Type Badge

    private func semanticTypeBadge(_ type: HoloMemorySemanticType) -> some View {
        Text(semanticTypeDisplayName(type))
            .holoText(.metadata)
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.holoPrimary.opacity(0.1))
            .cornerRadius(4)
    }

    private func semanticTypeDisplayName(_ type: HoloMemorySemanticType) -> String {
        switch type {
        case .phaseShift: return String(localized: "阶段变化")
        case .stablePattern: return String(localized: "稳定习惯")
        case .driftSignal: return String(localized: "偏离提醒")
        case .lifeEvent: return String(localized: "人生节点")
        case .statMilestone: return String(localized: "轻量记录")
        }
    }

    // MARK: - Evidence Preview

    private var evidencePreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(memory.evidence.prefix(2)) { ev in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.holoPrimary.opacity(0.3))
                        .frame(width: 4, height: 4)
                    Text(ev.excerpt)
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                }
            }
            if memory.evidence.count > 2 {
                Text("还有 \(memory.evidence.count - 2) 条证据")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
    }
}
