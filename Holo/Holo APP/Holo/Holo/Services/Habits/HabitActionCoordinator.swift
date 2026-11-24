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
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
    /// `deferCompletionHapticToLamp`：调用方是习惯今天页（行内有灯）时对「好习惯
    /// 当天首次打卡完成」把回执 success 触感延后到灯最亮那一刻（由 HabitLampView
    /// 播 soft）；没有灯的调用方（每日看板、详情页、意图路由）一律默认即时震动。
    func perform(_ kind: HabitActionKind, habitId: UUID, note: String? = nil,
                 deferCompletionHapticToLamp: Bool = false) async -> HabitActionResult? {
        guard !savingHabitIds.contains(habitId) else { return nil }
        savingHabitIds.insert(habitId)
        defer { savingHabitIds.remove(habitId) }

        let result: HabitActionResult
        var checkInLampEventArmed = false
        switch kind {
        case .toggleCheckIn:
            let (outcome, lampArmed) = performToggleCheckIn(habitId: habitId, note: note)
            result = outcome
            checkInLampEventArmed = lampArmed
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
        // 数值行没有灯（按钮不变灯），触感恒为回执即时档；只有打卡行可延后
        let lampDeferralActive = deferCompletionHapticToLamp && checkInLampEventArmed && Self.lampMotionAllowed
        playHabitHaptic(HabitHapticPolicy.haptic(for: kind, result: result,
                                                 lampDeferralActive: lampDeferralActive))
        return result
    }

    private func playHabitHaptic(_ haptic: HabitHapticPolicy.Haptic?) {
        switch haptic {
        case .success: HapticManager.success()
        case .light: HapticManager.light()
        // 已交给灯：灯最亮那一刻由 HabitLampView 播 soft
        case .deferredToLamp: break
        case nil: break
        }
    }

    /// 灯点亮动画是否允许播放（完成动效开关 + 系统减弱动态效果）。
    /// 灯不播时回执触感回落为即时档，不会出现「无灯也无震」。
    private static var lampMotionAllowed: Bool {
        guard HoloMotionPreferencePolicy.isEnabled(HoloMotionRollout.completionKey) else { return false }
        #if canImport(UIKit)
        return !UIAccessibility.isReduceMotionEnabled
        #else
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    // MARK: - 打卡

    private func performToggleCheckIn(habitId: UUID, note: String?) -> (HabitActionResult, lampEventArmed: Bool) {
        let wasRecorded: Bool
        if let habit = repository.findHabit(by: habitId) {
            wasRecorded = repository.isTodayCompleted(for: habit)
        } else {
            return (.invalidated(.habitUnavailable), false)
        }

        do {
            let data = try repository.performCheckInReceipt(habitId: habitId, note: note)
            let habit = repository.findHabit(by: habitId)
            let isFirstCompletion = data.newState && !wasRecorded
            // 好习惯完成暖光：Motion 中心自带当天去重，坏习惯不庆祝。
            // 世代值真的前进（事件入账：当天首次 + 开关开启 + 前台）才会有点亮动画，
            // 触感才允许延后；撤销后重勾、关动效、坏习惯都保持即时回执档
            var lampEventArmed = false
            if isFirstCompletion, let habit, !habit.isBadHabit {
                let subject = HoloMotionSubject(domain: .habit, id: habitId)
                let generationBefore = HoloMotionFeedbackCenter.shared.generations[subject]
                HoloMotionFeedbackCenter.shared.completedHabit(habitId)
                lampEventArmed = HoloMotionFeedbackCenter.shared.generations[subject] != generationBefore
            }
            return (.confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .toggleCheckIn,
                recordId: data.recordId,
                previousCheckInState: data.previousState,
                newCheckInState: data.newState,
                isTodayFirstCompletion: isFirstCompletion
            )), lampEventArmed)
        } catch let error as HabitError {
            switch error {
            case .notFound: return (.invalidated(.habitUnavailable), false)
            case .habitIsPaused: return (.invalidated(.habitPaused), false)
            case .invalidData: return (.invalidated(.typeNotSupported), false)
            default: return (.failed(error.localizedDescription), false)
            }
        } catch {
            return (.failed(String(localized: "这次没有保存成功，内容还在")), false)
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
            let recordId = try repository.performAddNumericReceipt(habitId: habitId, value: value, note: note)
            // 好习惯当天首次有效记录 → 完成暖光（Motion 中心当天去重；真实 0 也算记录）
            if !wasRecorded, let habit = repository.findHabit(by: habitId), !habit.isBadHabit {
                HoloMotionFeedbackCenter.shared.completedHabit(habitId)
            }
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .addNumeric(value: value),
                recordId: recordId,
                previousCheckInState: nil,
                newCheckInState: nil,
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
            guard let removed = try repository.removeLatestTodayRecordValue(for: habit) else {
                return .unchanged(.nothingToUndo)
            }
            return .confirmed(HabitActionReceipt(
                operationID: UUID(),
                habitId: habitId,
                kind: .removeLatestNumeric,
                recordId: nil,
                previousCheckInState: nil,
                newCheckInState: nil,
                isTodayFirstCompletion: false,
                removedNumericValue: removed
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

        // 提交时再校验一次日期与资格（弹层打开期间可能跨日/数据变化，方案 §10.1）；
        // 「今天」与创建日按习惯结算时间归属
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let today = habit.currentDay(calendar: calendar)
        guard dayStart < today else { return .invalidated(.futureDate) }
        guard dayStart >= habit.creationDay(calendar: calendar) else { return .invalidated(.beforeCreation) }

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

/// 记录动作 → 触觉档位映射。语义沿旧磁贴版：勾上打卡/当日首笔数值 = success，
/// 取消、追加、撤销与补录 = light；失败/无变化不震（各走行内错误文案）。
/// 例外（2026-11-23 审美七项 P1 §4.8）：好习惯当天首次打卡且这次交给灯点亮
/// （来源是习惯今天页 + 事件入账 + 动效允许）→ .deferredToLamp，回执不震，
/// 由 HabitLampView 在灯最亮那一刻播 soft；数值行没有灯，恒为即时档。
/// 坏习惯超限的 warning 震由超限警告 toast（HoloToastCenter .warning）自带。
enum HabitHapticPolicy {
    enum Haptic: Equatable { case success, light, deferredToLamp }

    static func haptic(for kind: HabitActionKind, result: HabitActionResult,
                       lampDeferralActive: Bool = false) -> Haptic? {
        guard case .confirmed(let receipt) = result else { return nil }
        switch kind {
        case .toggleCheckIn:
            if receipt.newCheckInState == true, receipt.isTodayFirstCompletion, lampDeferralActive {
                return .deferredToLamp
            }
            // 勾上恒 success（暖光才看当天首次）；取消 = light
            return receipt.newCheckInState == true ? .success : .light
        case .addNumeric, .increment:
            return receipt.isTodayFirstCompletion ? .success : .light
        case .removeLatestNumeric, .retroactive, .updateRecord, .deleteRecord:
            return .light
        }
    }
}
