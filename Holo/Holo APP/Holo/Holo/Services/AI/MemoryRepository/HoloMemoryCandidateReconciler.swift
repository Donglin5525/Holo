//
//  HoloMemoryCandidateReconciler.swift
//  Holo
//
//  激活策略升级后，按当前策略重评估历史待确认记忆。
//  每个策略版本只执行一次，用户已表态（userDecision != .none）的记录不动。
//

import Foundation
import OSLog

struct HoloMemoryCandidateReconcileResult: Equatable, Sendable {
    var reevaluatedCount: Int
    var activatedCount: Int
}

enum HoloMemoryCandidateReconciler {
    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryCandidateReconciler")
    private static let defaultsKey = "holo_memory_candidate_reconcile_policy_version"

    /// 策略版本升级后重评估存量待确认记忆；返回 nil 表示当前版本已执行过。
    static func reconcileIfNeeded(
        repository: any HoloMemoryRepository,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async throws -> HoloMemoryCandidateReconcileResult? {
        let completedVersion = defaults.integer(forKey: defaultsKey)
        guard completedVersion < HoloMemoryActivationPolicy.currentVersion else { return nil }
        defer { defaults.set(HoloMemoryActivationPolicy.currentVersion, forKey: defaultsKey) }

        let candidates = try await repository.query(.all).filter {
            $0.state == .candidate && $0.userDecision == .none
        }
        var result = HoloMemoryCandidateReconcileResult(reevaluatedCount: 0, activatedCount: 0)

        for candidate in candidates {
            var fixed = candidate
            // 修正「健康域一刀切」时代的误标：链路上 sensitivity 仅有该来源，
            // 凡因 sensitiveMemory 待确认的记录，其敏感标记均为误标。
            if fixed.adoptionMetadata?.reason == .sensitiveMemory,
               fixed.sensitivity != .normal {
                fixed.sensitivity = .normal
            }
            // 新策略下应丢弃的记录保持原状，由生命周期管理，不在此删除。
            guard var adopted = HoloMemoryActivationPolicy.apply(
                to: fixed,
                isFirstCrossDomainInference: fixed.scope == .crossDomain,
                now: now
            ) else { continue }
            adopted.recordVersion = candidate.recordVersion + 1
            adopted.predecessorVersionID = candidate.versionID

            // baseline 排除或墓碑拦截时 upsert 会返回拒绝结果，跳过即可。
            let upsertResult = try await repository.upsert(adopted, observationKey: nil)
            guard upsertResult == .inserted || upsertResult == .updated else { continue }
            result.reevaluatedCount += 1
            if adopted.state == .active { result.activatedCount += 1 }
        }

        if result.reevaluatedCount > 0 {
            logger.info(
                "待确认记忆重评估完成：\(result.reevaluatedCount, privacy: .public) 条重估，\(result.activatedCount, privacy: .public) 条生效"
            )
        }
        return result
    }
}
