//
//  TodayPlanOutletRow.swift
//  Holo
//
//  「今天减负」当日选择轻量出口（2026-10-03 实施方案 §12）
//  任务详情 / Matter 执行区共用：加入今天 ↔ 今天先放下。
//  今天到期/逾期任务的放下需要行内风险确认（这里只提示走「帮我理一理」），
//  出口不改期限、不改执行时段、不发通知。
//

import SwiftUI
import Combine
import os.log

struct TodayPlanOutletRow: View {

    let taskID: UUID
    @ObservedObject private var planChange = TodayPlanChangeObserver.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "TodayPlanOutlet")

    var body: some View {
        let scope = HoloTodayDayScope.current()
        let read = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext).currentPlan(scope: scope)
        let isSelected: Bool
        switch read.state {
        case .active(let payload, _):
            isSelected = payload.entry(for: taskID) != nil
        default:
            isSelected = false
        }

        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "moon.zzz" : "sun.max")
                .font(.caption)
                .foregroundStyle(Color.holoPrimary)
            Text(isSelected
                 ? String(localized: "这件事在今天的选择里")
                 : String(localized: "把这件事放进今天"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { @MainActor in
                    await toggle(selected: isSelected)
                }
            } label: {
                Text(isSelected ? String(localized: "今天先放下") : String(localized: "加入今天"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todayPlanOutlet-\(taskID.uuidString.prefix(8))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolBackground.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func toggle(selected: Bool) async {
        let scope = HoloTodayDayScope.current()
        let repository = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext)
        var heads: [UUID] = []
        if case .active(_, let headIDs) = repository.currentPlan(scope: scope).state {
            heads = headIDs
        }
        do {
            if selected {
                let facts = repository.facts(taskIDs: [taskID], stepIDs: [])
                let due = facts.tasks[taskID]?.dueDate
                let allDay = facts.tasks[taskID]?.isAllDay ?? false
                if HoloTodayReliefPolicy.needsDeadlineAcknowledgement(dueDate: due, isAllDay: allDay, scope: scope) {
                    // 今天到期/逾期：行内风险确认只在「帮我理一理」里给（避免详情页误放）
                    Self.logger.notice("今天到期的任务请在「帮我理一理」里确认放下")
                    return
                }
                _ = try await HoloTodayPlanService.shared.deferTask(
                    taskID: taskID, acknowledgement: nil,
                    scope: scope, expectedHeads: heads,
                    operationID: UUID().uuidString
                )
            } else {
                _ = try await HoloTodayPlanService.shared.addTask(
                    taskID: taskID, goal: .taskResult,
                    scope: scope, expectedHeads: heads,
                    operationID: UUID().uuidString
                )
            }
            HapticManager.light()
        } catch {
            Self.logger.error("今日选择调整失败: \(error.localizedDescription)")
        }
    }
}

/// 轻量计划变化观察者：让出口行跟随采用/调整即时刷新。
@MainActor
final class TodayPlanChangeObserver: ObservableObject {
    static let shared = TodayPlanChangeObserver()
    @Published private(set) var token = 0

    private init() {
        NotificationCenter.default.publisher(for: .holoTodayPlanDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.token += 1
            }
    }
}
