//
//  HabitRepository+InteractionRebuild.swift
//  Holo
//
//  2026-10 习惯交互重构新增的仓库能力：带回执动作、三态编辑、
//  归档查询、投影批量取数。仅主 App target 编译（Holo/ 同步组），
//  不进小组件 target——小组件不依赖展示层类型。
//

import Foundation
import CoreData
import os.log

extension HabitRepository {

    // MARK: - 带回执动作（2026-10 重构：协调器专用，旧 API 不动）
    // 保存失败时做「本操作范围」的内存恢复：新插入对象删除、翻转字段还原，
    // 绝不全局 rollback 共享 context（会抹掉其他模块待保存数据）。

    /// 打卡回执数据
    struct CheckInReceiptData {
        let recordId: UUID
        let previousState: Bool
        let newState: Bool
    }

    /// 打卡（返回回执；幂等复用既有取消态行，保持一天一条数据形态）
    func performCheckInReceipt(habitId: UUID, note: String? = nil) throws -> CheckInReceiptData {
        if !isReady { setup() }
        guard let habit = findHabit(by: habitId) else { throw HabitError.notFound }
        guard habit.isCheckInType else { throw HabitError.invalidData }
        guard !habit.isPaused else { throw HabitError.habitIsPaused }

        if let existing = findTodayCheckInRecord(for: habit) {
            let previous = existing.isCompleted
            existing.isCompleted.toggle()
            if existing.isCompleted, let note, !note.isEmpty {
                existing.note = note
            }
            do {
                try context.save()
            } catch {
                existing.isCompleted = previous
                throw error
            }
            notifyDataChange(habitId: habit.id)
            return CheckInReceiptData(recordId: existing.id, previousState: previous, newState: existing.isCompleted)
        }

        let record = HabitRecord.createCheckIn(in: context, habit: habit, isCompleted: true, note: note)
        do {
            try context.save()
        } catch {
            context.delete(record)
            throw error
        }
        notifyDataChange(habitId: habit.id)
        return CheckInReceiptData(recordId: record.id, previousState: false, newState: true)
    }

    /// 数值记录内容指纹（撤销前校验记录未被后续修改）
    static func recordFingerprint(_ record: HabitRecord) -> String {
        let valueText = record.value?.stringValue ?? "nil"
        let noteHash = (record.note ?? "").hashValue
        return "\(record.id.uuidString)|\(valueText)|\(noteHash)|\(record.date.timeIntervalSince1970)"
    }

    /// 新增数值记录（返回回执；调用方负责值合法性校验）
    func performAddNumericReceipt(habitId: UUID, value: Double, note: String? = nil) throws -> (recordId: UUID, fingerprint: String) {
        if !isReady { setup() }
        guard let habit = findHabit(by: habitId) else { throw HabitError.notFound }
        guard habit.isNumericType else { throw HabitError.invalidData }
        guard !habit.isPaused else { throw HabitError.habitIsPaused }
        guard value.isFinite else { throw HabitError.invalidData }

        let record = HabitRecord.createNumeric(in: context, habit: habit, value: value, note: note)
        do {
            try context.save()
        } catch {
            context.delete(record)
            throw error
        }
        notifyDataChange(habitId: habit.id)
        return (record.id, Self.recordFingerprint(record))
    }

    /// 撤销（删除）指定记录：按 record ID 精确删除，不做「删除最新一条」。
    /// 指纹不符说明记录已被修改（如用户已编辑），拒绝误删，返回 false。
    @discardableResult
    func performDeleteRecordReceipt(recordId: UUID, fingerprint: String) throws -> Bool {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        guard let record = try context.fetch(request).first else { return false }
        guard Self.recordFingerprint(record) == fingerprint else { return false }

        let habitId = record.habitId
        context.delete(record)
        do {
            try context.save()
        } catch {
            // scoped 恢复：save 失败时对象仍在 store，refresh 撤销内存中的删除标记
            context.refresh(record, mergeChanges: false)
            throw error
        }
        notifyDataChange(habitId: habitId)
        return true
    }

    // MARK: - 三态编辑（2026-10 重构：nil=不更新 无法表达「清除」，方案 §12.4）

    /// 完整编辑意图提交：基础字段 + 三态可清除字段 + 目标关系，一项用户意图一次事务。
    /// 保存失败时恢复本操作涉及的全部字段（scoped），草稿由 UI 保留重试。
    func applyHabitEdits(habitId: UUID, payload: HabitEditPayload) throws {
        if !isReady { setup() }
        guard let habit = findHabit(by: habitId) else { throw HabitError.notFound }

        // 原值快照（值类型，scoped 恢复用）
        let oName = habit.name
        let oIcon = habit.icon
        let oColor = habit.color
        let oType = habit.type
        let oFrequency = habit.frequency
        let oAggregation = habit.aggregationType
        let oTargetCount = habit.targetCount
        let oTargetValue = habit.targetValue
        let oUnit = habit.unit
        let oIsBad = habit.isBadHabit
        let oReminderMode = habit.habitReminderMode
        let oReminderTime = habit.reminderTime
        let oGoal = habit.goal

        func restore() {
            habit.name = oName
            habit.icon = oIcon
            habit.color = oColor
            habit.type = oType
            habit.frequency = oFrequency
            habit.aggregationType = oAggregation
            habit.targetCount = oTargetCount
            habit.targetValue = oTargetValue
            habit.unit = oUnit
            habit.isBadHabit = oIsBad
            habit.habitReminderMode = oReminderMode
            habit.reminderTime = oReminderTime
            habit.goal = oGoal
        }

        let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw HabitError.invalidData }

        let typeChanged = payload.type.rawValue != habit.type
        habit.name = trimmedName
        habit.icon = payload.icon
        habit.color = payload.color
        habit.frequency = payload.frequency.rawValue
        habit.aggregationType = payload.aggregationType.rawValue
        habit.isBadHabit = payload.isBadHabit
        habit.habitReminderMode = payload.reminderMode
        habit.reminderTime = payload.reminderTime
        if typeChanged {
            habit.type = payload.type.rawValue
            bridgeRecordsForTypeChange(habit, to: payload.type)
        }

        switch payload.targetCount {
        case .keep: break
        case .set(let value): habit.targetCount = NSNumber(value: value)
        case .clear: habit.targetCount = nil
        }
        switch payload.targetValue {
        case .keep: break
        case .set(let value): habit.targetValue = NSNumber(value: value)
        case .clear: habit.targetValue = nil
        }
        switch payload.unit {
        case .keep: break
        case .set(let value): habit.unit = value
        case .clear: habit.unit = nil
        }
        switch payload.goalId {
        case .keep: break
        case .set(let goalId):
            if let goalId {
                let request = Goal.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", goalId as CVarArg)
                request.fetchLimit = 1
                guard let goal = try context.fetch(request).first else {
                    throw HabitError.notFound  // 关系指向的目标不存在：报错重试，不静默丢关系
                }
                habit.goal = goal
            } else {
                habit.goal = nil
            }
        case .clear: habit.goal = nil
        }

        habit.updatedAt = Date()

        do {
            try context.save()
        } catch {
            restore()
            throw error
        }
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }

    // MARK: - 归档与投影取数（2026-10 重构）

    /// 通过 ID 取消归档（管理页；归档时保留的暂停状态不动，§6.1）
    func unarchiveHabitById(_ habitId: UUID) throws {
        if !isReady { setup() }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", habitId as CVarArg)
        request.fetchLimit = 1
        guard let habit = try context.fetch(request).first else { return }
        habit.isArchived = false
        habit.updatedAt = Date()
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }

    /// 已归档习惯（管理页「已归档」分组；软删排除）
    func fetchArchivedHabits() -> [Habit] {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == YES AND deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return Self.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 一次性取全部有效习惯的记录值（投影底座；固定 1 次 fetch，不随习惯数增长）
    func allRecordFacts() -> [HabitRecordFact] {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

        do {
            return try context.fetch(request).map { record in
                HabitRecordFact(
                    id: record.id,
                    habitId: record.habitId,
                    date: record.date,
                    isCompleted: record.isCompleted,
                    value: record.valueDouble,
                    isRetroactive: record.isRetroactive
                )
            }
        } catch {
            logger.error("取记录投影数据失败: \(error)")
            return []
        }
    }

    /// 指定习惯集合的暂停窗口（解码一次，投影判定复用）
    func pauseWindowsByIds(_ ids: [UUID]) -> [UUID: [HabitPauseWindow]] {
        var result: [UUID: [HabitPauseWindow]] = [:]
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@ AND deletedAt == nil", ids as NSArray)
        for habit in (try? context.fetch(request)) ?? [] {
            result[habit.id] = habit.pauseWindows
        }
        return result
    }
}
