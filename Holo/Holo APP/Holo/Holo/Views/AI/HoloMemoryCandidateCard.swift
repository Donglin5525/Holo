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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb")
                    .font(.system(size: 14))
                    .foregroundColor(.holoPrimary)
                Text(memory.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if memory.sensitivity != .normal {
                    sensitivityBadge
                }
            }

            Text(memory.summary)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(3)

            if !memory.evidence.isEmpty {
                evidencePreview
            }

            HStack(spacing: 12) {
                Button {
                    onReject()
                } label: {
                    Text("忽略")
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.holoTextSecondary.opacity(0.1))
                        .cornerRadius(8)
                }

                Button {
                    onConfirm()
                } label: {
                    Text("记住")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary)
                        .cornerRadius(8)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sensitivity Badge

    private var sensitivityBadge: some View {
        Text(memory.sensitivity == .sensitive ? "敏感" : "高影响")
            .font(.system(size: 11))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(4)
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
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }
            if memory.evidence.count > 2 {
                Text("还有 \(memory.evidence.count - 2) 条证据")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }
}
