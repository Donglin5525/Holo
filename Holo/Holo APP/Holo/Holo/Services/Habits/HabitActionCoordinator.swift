//
//  HabitActionCoordinator.swift
//  Holo
//
//  习惯动作协调层（2026-10 重构）：草稿校验、重复提交控制、调用 repository、
//  操作回执、scoped undo、错误映射。只有 repository 写真实数据；
//  本层不自建会员 bool，不在保存前播放成功反馈（方案 §11.1/§12.2）。
//

import Foundation
import Combine
import CoreData
import SwiftUI

@MainActor
final class HabitActionCoordinator: ObservableObject {

    static let shared = HabitActionCoordinator(repository: .shared)

    private let repository: HabitRepository

    /// 正在保存的习惯（同一习惯保存过程串行；不同习惯可独立操作）
    @Published var savingHabitIds: Set<UUID> = []

    init(repository: HabitRepository) {
        self.repository = repository
    }

    // MARK: - 动作入口

    /// 发起一次记录动作。返回 nil = 同习惯保存中，本次忽略（不产生新意图）。
    func perform(_ kind: HabitActionKind, habitId: UUID, note: String? = nil) async -> HabitActionResult? {
        guard !savingHabitIds.contains(habitId) else { return nil }
        savingHabitIds.insert(habitId)
        defer { savingHabitIds.remove(habitId) }

        let result: HabitActionResult
        switch kind {
        case .toggleCheckIn:
            result = performToggleCheckIn(habitId: habitId, note: note)
        case .addNumeric(let value):
            result = performAddNumeric(habitId: habitId, value: value, note: note)
        case .increment(let amount):
            result = performAddNumeric(habitId: habitId, value: Double(amount), note: note)
        case .removeLatestNumeric:
            result = performRemoveLatest(habitId: habitId)
        case .retroactive(let mode, let day, let value):
            result = performRetroactive(habitId: habitId, mode: mode, day: day, value: value, note: note)
        case .updateRecord(let recordId, let value, let recordNote):
            result = performUpdateRecord(habitId: habitId, recordId: recordId, value: value, note: recordNote)
        case .deleteRecord(let recordId):
            result = performDeleteRecord(habitId: habitId, recordId: recordId)
        }
        return result
    }

    // MARK: - 打卡

    private func performToggleCheckIn(habitId: UUID, note: String?) -> HabitActionResult {
        let wasRecorded: Bool
        if let habit = repository.findHabit(by: habitId) {
            wasRecorded = repository.isTodayCompleted(for: habit)
        } else {
            return .invalidated(.habitUnavailable)
        }

        do {
            let data = try repository.performCheckInReceipt(habitId: habitId, note: note)
            let habit = repository.findHabit(by: habitId)
            let isFirstCompletion = data.newState && !wasRecorded
            // 好习惯完成暖光：Motion 中心自带当天去重，坏习惯不庆祝
            if isFirstCompletion, let habit, !habit.isBadHabit {
                HoloMotionFeedbackCenter.shared.completedHabit(habitId)
            }
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .toggleCheckIn,
                recordId: data.recordId,
                previousCheckInState: data.previousState,
                newCheckInState: data.newState,
                recordFingerprint: nil,
                isTodayFirstCompletion: isFirstCompletion
            ))
        } catch let error as HabitError {
            switch error {
            case .notFound: return .invalidated(.habitUnavailable)
            case .habitIsPaused: return .invalidated(.habitPaused)
            case .invalidData: return .invalidated(.typeNotSupported)
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    // MARK: - 数值记录

    private func performAddNumeric(habitId: UUID, value: Double, note: String?) -> HabitActionResult {
        guard value.isFinite else { return .invalidated(.invalidValue) }
        // 校验（方案 §11.4）：计数 >0；测量有限非负（含 0）
        if let habit = repository.findHabit(by: habitId) {
            if habit.isCountType, value <= 0 { return .invalidated(.invalidValue) }
            if habit.isMeasureType, value < 0 { return .invalidated(.invalidValue) }
        } else {
            return .invalidated(.habitUnavailable)
        }

        let wasRecorded: Bool
        if let habit = repository.findHabit(by: habitId) {
            wasRecorded = repository.getTodayValue(for: habit) != nil
        } else {
            return .invalidated(.habitUnavailable)
        }

        do {
            let data = try repository.performAddNumericReceipt(habitId: habitId, value: value, note: note)
            // 好习惯当天首次有效记录 → 完成暖光（Motion 中心当天去重；真实 0 也算记录）
            if !wasRecorded, let habit = repository.findHabit(by: habitId), !habit.isBadHabit {
                HoloMotionFeedbackCenter.shared.completedHabit(habitId)
            }
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .addNumeric(value: value),
                recordId: data.recordId,
                previousCheckInState: nil,
                newCheckInState: nil,
                recordFingerprint: data.fingerprint,
                isTodayFirstCompletion: !wasRecorded
            ))
        } catch let error as HabitError {
            return mapRepositoryError(error)
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    /// 计数减号：撤销最近一条今日记录（既有语义；含义在 UI 呈现，不做 total−1）
    private func performRemoveLatest(habitId: UUID) -> HabitActionResult {
        guard let habit = repository.findHabit(by: habitId) else {
            return .invalidated(.habitUnavailable)
        }
        do {
            let removed = try repository.removeLatestTodayRecord(for: habit)
            guard removed else { return .unchanged(.nothingToUndo) }
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .removeLatestNumeric,
                recordId: nil,
                previousCheckInState: nil,
                newCheckInState: nil,
                recordFingerprint: nil,
                isTodayFirstCompletion: false
            ))
        } catch let error as HabitError {
            return mapRepositoryError(error)
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    // MARK: - 补签 / 补记

    private func performRetroactive(
        habitId: UUID,
        mode: HabitRetroactiveMode,
        day: Date,
        value: Double?,
        note: String?
    ) -> HabitActionResult {
        guard let habit = repository.findHabit(by: habitId) else {
            return .invalidated(.habitUnavailable)
        }
        guard !habit.isBadHabit, habit.isCheckInType || habit.isNumericType else {
            return .invalidated(.typeNotSupported)
        }
        if habit.isArchived { return .invalidated(.archivedNeedsUnarchive) }

        // 提交时再校验一次日期与资格（弹层打开期间可能跨日/数据变化，方案 §10.1）
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: Date())
        guard dayStart < today else { return .invalidated(.futureDate) }
        guard dayStart >= calendar.startOfDay(for: habit.createdAt) else { return .invalidated(.beforeCreation) }

        do {
            let result = try repository.retroactiveCheckIn(
                for: habit,
                on: day,
                value: value,
                note: note,
                allowsFullHistory: mode == .backfill
            )
            switch result {
            case .success:
                return .confirmed(HabitActionReceipt(
                    operationID: UUID(),
                    habitId: habitId,
                    kind: .retroactive(mode: mode, day: dayStart, value: value),
                    recordId: nil,
                    previousCheckInState: nil,
                    newCheckInState: nil,
                    recordFingerprint: nil,
                    isTodayFirstCompletion: false
                ))
            case .alreadyCompleted:
                return .unchanged(.alreadyRecorded)
            case .invalidDate:
                return .invalidated(.invalidDate)
            case .requiresPlus:
                return .requiresEntitlement(.retroactiveQuotaExhausted)
            }
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    // MARK: - 记录明细

    private func performUpdateRecord(habitId: UUID, recordId: UUID, value: Double?, note: String?) -> HabitActionResult {
        if let value, !value.isFinite { return .invalidated(.invalidValue) }
        do {
            guard let record = findRecord(recordId) else { return .invalidated(.recordChanged) }
            try repository.updateRecord(record, value: value, note: note)
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .updateRecord(recordId: recordId, value: value, note: note),
                recordId: recordId,
                previousCheckInState: nil,
                newCheckInState: nil,
                recordFingerprint: nil,
                isTodayFirstCompletion: false
            ))
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    private func performDeleteRecord(habitId: UUID, recordId: UUID) -> HabitActionResult {
        do {
            guard let record = findRecord(recordId) else { return .invalidated(.recordChanged) }
            try repository.deleteRecord(record)
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .deleteRecord(recordId: recordId),
                recordId: recordId,
                previousCheckInState: nil,
                newCheckInState: nil,
                recordFingerprint: nil,
                isTodayFirstCompletion: false
            ))
        } catch {
            return .failed(String(localized: "这次没有保存成功，内容还在"))
        }
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? repository.context.fetch(request).first
    }

    // MARK: - Scoped Undo（方案 §11.3）

    /// 撤销一次已确认操作。只撤销本次新增/本次状态修改；
    /// 操作对象已被修改时不强行覆盖，返回 invalidated(.recordChanged)。
    func undo(_ receipt: HabitActionReceipt) -> HabitActionResult {
        switch receipt.kind {
        case .toggleCheckIn:
            // 校验当前记录状态与回执一致（未被用户或同步改动）
            guard let recordId = receipt.recordId,
                  let record = findRecord(recordId),
                  record.isCompleted == receipt.newCheckInState else {
                return .invalidated(.recordChanged)
            }
            do {
                _ = try repository.performCheckInReceipt(habitId: receipt.habitId)
                HoloMotionFeedbackCenter.shared.cancelHabitResponse(receipt.habitId)
                return .confirmed(HabitActionReceipt(
                    operationID: UUID(),
                    habitId: receipt.habitId,
                    kind: .toggleCheckIn,
                    recordId: recordId,
                    previousCheckInState: receipt.newCheckInState,
                    newCheckInState: receipt.previousCheckInState,
                    recordFingerprint: nil,
                    isTodayFirstCompletion: false
                ))
            } catch {
                return .failed(String(localized: "这次没有保存成功，内容还在"))
            }

        case .addNumeric:
            guard let recordId = receipt.recordId,
                  let fingerprint = receipt.recordFingerprint else {
                return .invalidated(.recordChanged)
            }
            do {
                let removed = try repository.performDeleteRecordReceipt(recordId: recordId, fingerprint: fingerprint)
                if removed {
                    HoloMotionFeedbackCenter.shared.cancelHabitResponse(receipt.habitId)
                    return .confirmed(HabitActionReceipt(
                        operationID: UUID(),
                        habitId: receipt.habitId,
                        kind: .deleteRecord(recordId: recordId),
                        recordId: recordId,
                        previousCheckInState: nil,
                        newCheckInState: nil,
                        recordFingerprint: nil,
                        isTodayFirstCompletion: false
                    ))
                }
                return .invalidated(.recordChanged)
            } catch {
                return .failed(String(localized: "这次没有保存成功，内容还在"))
            }

        case .increment, .removeLatestNumeric, .retroactive, .updateRecord, .deleteRecord:
            // 这几类不开放短提示撤销（补录跨日、明细编辑有自己的入口）
            return .invalidated(.recordChanged)
        }
    }

    // MARK: - 错误映射

    private func mapRepositoryError(_ error: HabitError) -> HabitActionResult {
        switch error {
        case .notFound: return .invalidated(.habitUnavailable)
        case .habitIsPaused: return .invalidated(.habitPaused)
        case .invalidData: return .invalidated(.invalidValue)
        default: return .failed(error.localizedDescription)
        }
    }
}
