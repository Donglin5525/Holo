//
//  HoloMemoryCandidateReconciler.swift
//  Holo
//
//  存量候选记忆的 v4 幂等迁移（低确认成本方案 §14）。
//
//  - 版本门控：每个策略版本只执行一次；仅完整成功才推进版本号，中断可续跑；
//  - 用户已表态（userDecision != .none）与终态记录不动（§14.1）；
//  - v4 判定丢弃的存量候选归档保留审计，不再滞留 candidate（§14.2-7）；
//  - 迁移禁止联网/LLM：全部按本地字段保守重算（§14.2）；
//  - journal：迁移前后基线快照（仅 metadata）落盘，供对账与 Debug 实验室展示（§14.3）；
//  - 旧 needsConfirmation 回执一次性消化，不再触发每日胶囊（§14.3）。
//

import Foundation
import OSLog

struct HoloMemoryCandidateReconcileResult: Codable, Equatable, Sendable {
    var reevaluatedCount: Int
    var activatedCount: Int
    var archivedCount: Int
}

/// v4 迁移 journal（仅 metadata，不含记忆正文）。
struct HoloMemoryMigrationJournal: Codable, Equatable, Sendable {
    var policyVersion: Int
    var startedAt: Date
    var finishedAt: Date?
    var before: HoloMemoryDecisionBaselineSnapshot
    var after: HoloMemoryDecisionBaselineSnapshot?
    var result: HoloMemoryCandidateReconcileResult?
}

enum HoloMemoryCandidateReconciler {
    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryCandidateReconciler")
    private static let defaultsKey = "holo_memory_candidate_reconcile_policy_version"

    static func reconcileIfNeeded(
        repository: any HoloMemoryRepository,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async throws -> HoloMemoryCandidateReconcileResult? {
        let completedVersion = defaults.integer(forKey: defaultsKey)
        guard completedVersion < HoloMemoryActivationPolicy.currentVersion else { return nil }

        let allRecords = try await repository.query(.all)
        let before = HoloMemoryDecisionBaselineSnapshotBuilder.build(records: allRecords, now: now)
        var journal = HoloMemoryMigrationJournal(
            policyVersion: HoloMemoryActivationPolicy.currentVersion,
            startedAt: now,
            finishedAt: nil,
            before: before,
            after: nil,
            result: nil
        )

        let candidates = allRecords.filter {
            $0.state == .candidate && $0.userDecision == .none
        }
        var result = HoloMemoryCandidateReconcileResult(
            reevaluatedCount: 0,
            activatedCount: 0,
            archivedCount: 0
        )

        for candidate in candidates {
            var fixed = candidate
            // 修正「健康域一刀切」时代的误标：链路上 sensitivity 仅有该来源，
            // 凡因 sensitiveMemory 待确认的记录，其敏感标记均为误标。
            if fixed.adoptionMetadata?.reason == .sensitiveMemory,
               fixed.sensitivity != .normal {
                fixed.sensitivity = .normal
            }

            if var adopted = HoloMemoryActivationPolicy.apply(
                to: fixed,
                isFirstCrossDomainInference: fixed.scope == .crossDomain,
                now: now
            ) {
                adopted.recordVersion = candidate.recordVersion + 1
                adopted.predecessorVersionID = candidate.versionID
                // baseline 排除或墓碑拦截时 upsert 会返回拒绝结果，跳过即可。
                let upsertResult = try await repository.upsert(adopted, observationKey: nil)
                guard upsertResult == .inserted || upsertResult == .updated else { continue }
                result.reevaluatedCount += 1
                if adopted.state == .active { result.activatedCount += 1 }
            } else if HoloMemoryDecisionPolicy.isEnabled {
                // v4 判定丢弃：归档保留正文与证据（审计可回溯），退出 candidate 库存。
                let decision = HoloMemoryDecisionPolicy.evaluate(fixed, now: now)
                var archived = fixed
                archived.state = .archived
                archived.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(v2: decision.metadata)
                archived.recordVersion = candidate.recordVersion + 1
                archived.predecessorVersionID = candidate.versionID
                try await repository.replaceRecordForUserControl(archived)
                result.archivedCount += 1
            }
            // v4 关闭（回滚态）下 apply 为 nil 的记录保持原状，由生命周期管理（v3 行为不变）。
        }

        // 旧确认回执一次性消化（不产生新回执、不触发主动提示）。
        #if !HOLO_MEMORY_STANDALONE
        HoloMemoryReceiptStore.markLegacyConfirmationReceiptsMigrated(now: now)
        #endif

        // 完整成功才推进版本 + 写终态 journal；中途抛错时下次启动续跑。
        let afterRecords = try await repository.query(.all)
        let after = HoloMemoryDecisionBaselineSnapshotBuilder.build(records: afterRecords, now: now)
        journal.after = after
        journal.result = result
        journal.finishedAt = now
        #if !HOLO_MEMORY_STANDALONE
        writeJournal(journal)
        #endif

        defaults.set(HoloMemoryActivationPolicy.currentVersion, forKey: defaultsKey)

        if result.reevaluatedCount > 0 || result.archivedCount > 0 {
            logger.info(
                "存量候选迁移完成：\(result.reevaluatedCount, privacy: .public) 条重估，\(result.activatedCount, privacy: .public) 条生效，\(result.archivedCount, privacy: .public) 条归档"
            )
        }
        return result
    }

    /// journal 落盘（仅 metadata）：Application Support/Holo/MemoryMigration/v{N}-journal.json。
    /// 写失败不阻断迁移（journal 是审计件，不是迁移前提）。
    #if !HOLO_MEMORY_STANDALONE
    private static func writeJournal(_ journal: HoloMemoryMigrationJournal) {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let url = directory
            .appendingPathComponent("Holo/MemoryMigration", isDirectory: true)
            .appendingPathComponent("v\(journal.policyVersion)-journal.json")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(journal).write(to: url, options: .atomic)
        } catch {
            logger.error("迁移 journal 写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
