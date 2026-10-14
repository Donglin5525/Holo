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
    @State private var pendingDiscard: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("有一个想到一半的目标")
                .font(.headline)
            ForEach(candidates, id: \.id) { session in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
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
                        .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    HStack(spacing: HoloSpacing.sm) {
                        Button("继续") { onResume(session.id) }
                            .buttonStyle(HoloActionStyle(role: .primary))
                        HoloIconButton(systemName: "trash", title: "放弃规划") {
                            pendingDiscard = session.id
                        }
                    }
                }
                .padding(10)
                .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            Button(action: onStartFresh) {
                Text("换个新的想法")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HoloActionStyle(role: .secondary))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
        .confirmationDialog("放弃这份规划？", isPresented: Binding(
            get: { pendingDiscard != nil },
            set: { if !$0 { pendingDiscard = nil } }
        ), titleVisibility: .visible) {
            if let id = pendingDiscard {
                Button("放弃规划", role: .destructive) {
                    pendingDiscard = nil
                    onDiscard(id)
                }
            }
            Button("取消", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("这份未完成的规划将被删除，已有目标不受影响。")
        }
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
