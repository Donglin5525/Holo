//
//  AnniversaryTaskGenerator.swift
//  Holo
//
//  纪念日 → 任务 自动生成器
//
//  职责：扫描「开启生成任务」的纪念日，为本周期生成对应的待办任务。
//  - 每年重复的：每个周年周期生成一条新任务
//  - 不重复的：提前提醒日期到达后生成一条
//  - 幂等：同一周期不会重复生成（通过 sourceAnniversaryId + 目标日期查重）
//

import Foundation
import CoreData
import os.log

@MainActor
final class AnniversaryTaskGenerator {

    static let shared = AnniversaryTaskGenerator()

    private let logger = Logger(subsystem: "com.holo.app", category: "AnniversaryTaskGen")

    private init() {}

    // MARK: - 核心入口

    /// 扫描并生成所有「该生成但未生成」的纪念日任务。
    /// 幂等：同一纪念日同一周期只生成一条。
    /// 使用主线程 viewContext（与 TodoRepository 一致），整体由调用方 await。
    /// - Parameter reference: 参考日期（默认今天），用于判断"是否到达生成时机"
    /// - Returns: 本次新生成的任务数量
    @discardableResult
    func generateDueTasks(asOf reference: Date = Date()) async -> Int {
        let todoRepo = TodoRepository.shared
        let anniversaryRepo = AnniversaryRepository.shared
        let context = todoRepo.context
        var generated = 0

        let anniversaries = anniversaryRepo.allAnniversaries()
            .filter { $0.reminderEnabled && $0.generateTask }

        for anniversary in anniversaries {
            guard shouldGenerate(for: anniversary, asOf: reference) else { continue }
            guard let targetDate = targetDate(for: anniversary, asOf: reference) else { continue }

            // 幂等检查：同一纪念日同一目标日期，已有未删除任务则跳过
            if taskAlreadyExists(for: anniversary.id, targetDate: targetDate, in: context) {
                continue
            }

            let title = taskTitle(for: anniversary)
            let dueDate = makeDueDate(targetDate: targetDate)

            do {
                let task = try todoRepo.createTask(
                    title: title,
                    description: taskDescription(for: anniversary),
                    priority: .medium,
                    dueDate: dueDate,
                    isAllDay: true
                )
                // 标记来源纪念日
                task.sourceAnniversaryId = anniversary.id
                try context.save()
                generated += 1
                logger.info("为纪念日「\(anniversary.title)」生成任务，目标日期 \(dueDate)")
            } catch {
                logger.error("生成纪念日任务失败：\(error.localizedDescription)")
            }
        }

        if generated > 0 {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
            }
        }
        return generated
    }

    // MARK: - 判断逻辑

    /// 判断某个纪念日当前是否该生成任务。
    /// 生成时机 = 目标日期 - 提前天数 <= 今天（即"提醒时间已到"）。
    private func shouldGenerate(for anniversary: Anniversary, asOf reference: Date) -> Bool {
        guard let triggerDate = triggerDate(for: anniversary, asOf: reference) else { return false }
        let today = Calendar.current.startOfDay(for: reference)
        return triggerDate <= today
    }

    /// 任务的目标日期（周年当天 / 单次日期）。
    private func targetDate(for anniversary: Anniversary, asOf reference: Date) -> Date? {
        let calendar = Calendar.current
        if anniversary.repeatYearly {
            return calendar.startOfDay(for: anniversary.nextOccurrenceDate(reference: reference))
        }
        return calendar.startOfDay(for: anniversary.date)
    }

    /// 提醒触发日期（目标日期 - 提前天数）。
    private func triggerDate(for anniversary: Anniversary, asOf reference: Date) -> Date? {
        guard let target = targetDate(for: anniversary, asOf: reference) else { return nil }
        return Calendar.current.date(byAdding: .day, value: -Int(anniversary.reminderDaysBefore), to: target)
    }

    /// 任务的截止日期 = 目标当天 23:59。
    private func makeDueDate(targetDate: Date) -> Date {
        Calendar.current.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: targetDate
        ) ?? targetDate
    }

    // MARK: - 幂等查重

    /// 检查同一纪念日、同一目标日期是否已有未删除的任务。
    private func taskAlreadyExists(
        for anniversaryId: UUID,
        targetDate: Date,
        in context: NSManagedObjectContext
    ) -> Bool {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: targetDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "sourceAnniversaryId == %@ AND dueDate >= %@ AND dueDate < %@ AND deletedFlag == NO",
            anniversaryId as CVarArg,
            dayStart as CVarArg,
            dayEnd as CVarArg
        )
        request.fetchLimit = 1
        let count = (try? context.count(for: request)) ?? 0
        return count > 0
    }

    // MARK: - 文案

    /// 任务标题：图标 + 名称 + 临近描述
    private func taskTitle(for anniversary: Anniversary) -> String {
        let icon = anniversary.icon
        let name = anniversary.title
        let days = anniversary.displayDays
        let unit: String
        switch anniversary.displayMode {
        case .countdown(let d):
            unit = d == 0 ? "就是今天" : "还有\(days)天"
        case .elapsed:
            unit = "已经\(days)天"
        }
        return "\(icon) \(name) \(unit)"
    }

    /// 任务描述：来源说明 + 备注
    private func taskDescription(for anniversary: Anniversary) -> String {
        var desc = "来自纪念日「\(anniversary.title)」"
        if let note = anniversary.note, !note.isEmpty {
            desc += "\n\(note)"
        }
        return desc
    }

    // MARK: - 清理

    /// 删除某个纪念日的所有关联任务（删除纪念日时可选调用）。
    func deleteTasks(for anniversaryId: UUID) async {
        let context = TodoRepository.shared.context
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "sourceAnniversaryId == %@ AND deletedFlag == NO",
            anniversaryId as CVarArg
        )
        guard let tasks = try? context.fetch(request) as [TodoTask] else { return }
        for task in tasks {
            task.deletedFlag = true
            task.deletedAt = Date()
        }
        try? context.save()
        if !tasks.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
            }
        }
    }
}
