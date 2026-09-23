//
//  HoloMatterPlanLaunchCoordinator.swift
//  Holo
//
//  Matter V2「开始推进」UI 唯一入口（2026-09-21 方案 §7.1）。
//
//  职责边界：预检重复（幂等恢复/同名歧义）→ 委托 HoloMatterRepository.launchPlan
//  → 事务成功后刷新 Todo / Matter 观察者。本层不写业务数据。
//
//  R1 = 底座 + 预检；R2 由 ContextPlanChatCard 接入（旧 HoloMatterActivationCoordinator
//  随开关退役，不在新路径上）。
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class HoloMatterPlanLaunchCoordinator: ObservableObject {

    static let shared = HoloMatterPlanLaunchCoordinator()

    /// 卡片按钮状态（ready → launching → launched / failure）。
    @Published private(set) var inFlight = false

    enum LaunchPreparation: Equatable {
        /// 无重复：可直接启动（不弹第二个确认表单）。
        case ready
        /// 同来源已启动过：卡片按 origin link 恢复回执，不重复执行。
        case alreadyLaunched
        /// 同名 active Matter：弹一次最小歧义确认（默认主操作 = 继续已有）。
        case duplicateChoice(existingMatterID: UUID)
    }

    /// 启动前预检（方案 §3.4）。
    func prepare(
        request: HoloMatterPlanLaunchRequest,
        repository: HoloMatterRepository = .shared
    ) -> LaunchPreparation {
        if repository.findMatterActivated(from: request.contextPlanMessageID) != nil {
            return .alreadyLaunched
        }
        let normalized = Self.normalizedTitle(request.confirmedTitle)
        if !normalized.isEmpty,
           let existing = repository.matters(lifecycles: [.active])
            .first(where: { Self.normalizedTitle($0.title) == normalized }) {
            return .duplicateChoice(existingMatterID: existing.id)
        }
        return .ready
    }

    /// 启动：成功只能以 receipt 为准。事务成功后广播 Todo 数据变更，
    /// 各模块观察者自行刷新（Matter 侧由 Repository.changeToken 驱动）。
    func launch(
        request: HoloMatterPlanLaunchRequest,
        repository: HoloMatterRepository = .shared
    ) async throws -> HoloMatterPlanLaunchReceipt {
        guard !inFlight else {
            throw HoloMatterPlanLaunchError.launchAlreadyInFlight
        }
        inFlight = true
        defer { inFlight = false }
        let receipt = try await repository.launchPlan(request: request)
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
        return receipt
    }

    /// 与 Repository 标准化口径一致（trim + 60 字上限），用于同名判定。
    nonisolated private static func normalizedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(60))
    }
}
