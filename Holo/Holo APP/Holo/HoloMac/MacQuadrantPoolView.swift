//
//  MacQuadrantPoolView.swift
//  HoloMac
//
//  待确认横条：条头（tray + 计数徽章 + 引导语）+ 紧凑行卡横向滚动。
//  池是分类入口不是拖入目标（政策禁止移入待确认），整条不挂 dropDestination。
//

import SwiftUI

struct MacQuadrantPoolView: View {

    let tasks: [TodoTask]
    let pendingTaskID: UUID?
    @Binding var selectedTaskId: UUID?
    let actions: MacQuadrantBoardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                Text(String(localized: "待确认"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolText)
                HoloCountBadge(count: tasks.count)
                Text(String(localized: "先判断重要性，再决定放在哪里"))
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "待确认，\(tasks.count)项"))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(tasks, id: \.id) { task in
                        row(task)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 46)
        }
        .padding(HoloSpacing.sm + 4)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoCardBackground))
        .accessibilityIdentifier("mac.task.board.pool")
    }

    private func row(_ task: TodoTask) -> some View {
        MacQuadrantTaskRow(
            task: task,
            isCompleting: pendingTaskID == task.id,
            isSelected: selectedTaskId == task.id,
            onToggleCompletion: { actions.onToggleCompletion(task, nil) },
            onSelect: { actions.onSelect(task) })
            .contextMenu {
                MacQuadrantTaskMenu.menuContent(
                    for: task,
                    currentQuadrant: .unclassified,
                    actions: actions)
            }
    }
}
