//
//  GoalWorkshopDefinitionCard.swift
//  Holo
//
//  目标共创·定义/草案卡（方案任务 5）：确认页前置摘要——
//  期望结果、成功证据、所选路径及代价、关键假设、里程碑、第一步。
//  完整字段编辑在确认页（GoalDraftReviewView，任务 6 扩展）完成。
//

import SwiftUI

struct GoalWorkshopDefinitionCard: View {
    let session: GoalWorkshopSessionV1
    let isExistingGoalAdvice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isExistingGoalAdvice {
                Label {
                    Text("以下是调整建议，尚未修改原目标")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if let definition = session.goalDefinition {
                Text(definition.title)
                    .font(.headline)
                if let outcome = definition.desiredOutcome, !outcome.isEmpty {
                    row("期望结果", outcome)
                }
                if let deadline = definition.deadlineText, !deadline.isEmpty {
                    row("期限", deadline)
                }
            }

            if let plan = session.plan {
                row("成功标准", plan.successEvidence)
                if let routeTitle = selectedRouteTitle {
                    row("所选路径", routeTitle)
                }
                if !plan.assumptions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("关键假设（未确认信息，可改）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(plan.assumptions, id: \.self) { assumption in
                            Label {
                                Text(assumption).font(.footnote)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                if !plan.milestones.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("里程碑").font(.footnote).foregroundStyle(.secondary)
                        ForEach(plan.milestones) { milestone in
                            Label {
                                HStack {
                                    Text(milestone.title).font(.footnote)
                                    if let date = milestone.dateText {
                                        Text(date).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "flag")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                if let first = firstActionTitle {
                    Label {
                        Text("第一步：\(first)")
                    } icon: {
                        Image(systemName: "shoe")
                    }
                    .font(.subheadline)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedRouteTitle: String? {
        guard let selected = session.selectedRouteID else { return nil }
        return session.routeOptions.first { $0.id == selected }?.title
    }

    private var firstActionTitle: String? {
        guard let plan = session.plan, let first = plan.firstActionID else { return nil }
        if let task = plan.draft.tasks.first(where: { $0.id == first }) { return task.title }
        if let habit = plan.draft.habits.first(where: { $0.id == first }) { return habit.name }
        return nil
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }
}
