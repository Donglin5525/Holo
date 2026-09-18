//
//  GoalWorkshopResumeCard.swift
//  Holo
//
//  目标共创·恢复卡（方案任务 5）：已有未完成草案先给「继续/放弃/另建」，不自动覆盖
//

import SwiftUI

struct GoalWorkshopResumeCard: View {
    let candidates: [GoalWorkshopSessionV1]
    let onResume: (UUID) -> Void
    let onDiscard: (UUID) -> Void
    let onStartFresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("有一个想到一半的目标")
                .font(.headline)
            ForEach(candidates, id: \.id) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.originalText.isEmpty ? "（未命名的心愿）" : session.originalText)
                            .font(.subheadline)
                            .lineLimit(2)
                        Label {
                            Text(phaseLabel(session.phase))
                                .font(.caption)
                        } icon: {
                            Image(systemName: phaseIcon(session.phase))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("继续") { onResume(session.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button {
                        onDiscard(session.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            Button(action: onStartFresh) {
                Text("换个新的想法")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func phaseLabel(_ phase: GoalWorkshopPhase) -> LocalizedStringKey {
        switch phase {
        case .understanding: return "正在想清楚"
        case .exploring: return "在比较路径"
        case .choosing: return "已选路径，待出草案"
        case .reviewing: return "草案待确认"
        case .saved: return "已保存"
        case .abandoned: return "已放弃"
        }
    }

    private func phaseIcon(_ phase: GoalWorkshopPhase) -> String {
        switch phase {
        case .understanding: return "text.bubble"
        case .exploring: return "arrow.triangle.branch"
        case .choosing: return "hand.point.up.left"
        case .reviewing: return "checklist"
        case .saved: return "checkmark.circle"
        case .abandoned: return "xmark.circle"
        }
    }
}
