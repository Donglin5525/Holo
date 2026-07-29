//
//  HoloAgentPersistenceTransaction.swift
//  Holo
//
//  多 store 写入的事务闸门 + journal（§11.8）。
//
//  解决的真实问题：saveProgress 顺序写 evidence → checkpoint → job，
//  崩溃在中间会留下「checkpoint 存在但 job 未更新」的不一致态。
//  现有 Reconciler 能修复大部分，但只能事后猜测。
//
//  journal 的价值：在多 store 写入前先写一份「意图清单」（写到独立文件），
//  写入完成后删除。崩溃后 Reconciler 读到残留 journal 就能精确知道
//  「这次写入计划做什么、做到哪了」，做精确前滚或回滚。
//
//  设计为最小介入：journal 只记录写入意图的元信息（jobID + 步骤 + 时间），
//  不复制实际数据（实际数据已由各 store 的原子写保证）。
//

import Foundation

/// 一个事务步骤。
nonisolated enum HoloAgentPersistenceStep: String, Codable, Sendable {
    case begin          // 意图已记录，写入尚未开始
    case evidenceWritten // evidence 已落盘
    case checkpointWritten // checkpoint 已落盘
    case jobWritten      // job 已落盘
    case committed       // 全部完成，journal 可清理
}

/// 单条事务 journal 记录。
nonisolated struct HoloAgentPersistenceJournalEntry: Codable, Equatable, Sendable {
    var jobID: String
    var lastStep: HoloAgentPersistenceStep
    var startedAt: Date
    var updatedAt: Date
}

/// 事务闸门：管理 journal 文件，协调多 store 写入的可恢复性。
/// actor 隔离保证 journal 读写串行化。
actor HoloAgentPersistenceTransactionGate {

    private let journalURL: URL

    init(directory: URL? = nil) {
        if let directory {
            self.journalURL = directory.appendingPathComponent("agentTransactions.json")
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.journalURL = dir.appendingPathComponent("agentTransactions.json")
        }
    }

    // MARK: - Journal 读写

    /// 读出当前所有未提交（残留）事务。正常情况下为空——崩溃后才有残留。
    func loadPending() async -> [HoloAgentPersistenceJournalEntry] {
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        return (try? JSONDecoder().decode([HoloAgentPersistenceJournalEntry].self, from: data)) ?? []
    }

    /// 记录或更新一条事务步骤。
    func record(jobID: String, step: HoloAgentPersistenceStep, now: Date = Date()) async {
        var entries = loadPendingSync()
        if let index = entries.firstIndex(where: { $0.jobID == jobID }) {
            entries[index].lastStep = step
            entries[index].updatedAt = now
        } else {
            entries.append(HoloAgentPersistenceJournalEntry(
                jobID: jobID, lastStep: step, startedAt: now, updatedAt: now
            ))
        }
        persistSync(entries)
    }

    /// 事务提交完成：从 journal 移除该 job 的记录。
    func clear(jobID: String) async {
        var entries = loadPendingSync()
        entries.removeAll { $0.jobID == jobID }
        persistSync(entries)
    }

    /// 移除某 job 的残留 journal（Reconciler 处理后调用）。
    func discard(jobID: String) async {
        await clear(jobID: jobID)
    }

    // MARK: - 同步内部实现（journal 文件小，同步 IO 可接受）

    private func loadPendingSync() -> [HoloAgentPersistenceJournalEntry] {
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        return (try? JSONDecoder().decode([HoloAgentPersistenceJournalEntry].self, from: data)) ?? []
    }

    private func persistSync(_ entries: [HoloAgentPersistenceJournalEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let tmp = journalURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(journalURL, withItemAt: tmp)
        } catch {
            // journal 写失败不应阻塞主流程（它只是恢复辅助）；记日志即可。
            // 实际生产可接 os.log，这里保持最小依赖。
            try? data.write(to: journalURL, options: .atomic)
        }
    }
}
