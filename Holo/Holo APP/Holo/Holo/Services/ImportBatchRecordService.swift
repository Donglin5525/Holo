//
//  ImportBatchRecordService.swift
//  Holo
//
//  导入批次记录服务 — 持久化最近导入批次，支持 24 小时内按批次撤回
//
//  设计：用 UserDefaults 存 Codable 数组。批次记录很小（每条几十字节），
//  且只保留 24 小时内的，不会无限增长。长期保留需求后续再迁移到 Core Data 实体。
//

import Foundation

/// 导入批次记录服务（单例）
enum ImportBatchRecordService {

    private static let storageKey = "importBatchRecords"

    // MARK: - 读写

    /// 记录一次导入批次
    static func record(_ batchRecord: ImportBatchRecord) {
        var records = loadAll()
        records.append(batchRecord)
        // 只保留 24 小时内的（加上一点缓冲）
        let cutoff = Date().addingTimeInterval(-25 * 3600)
        records = records.filter { $0.importedAt > cutoff }
        saveAll(records)
    }

    /// 获取最近 24 小时内的批次记录（按时间倒序）
    static func recentWithin24h() -> [ImportBatchRecord] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return loadAll()
            .filter { $0.importedAt > cutoff }
            .sorted { $0.importedAt > $1.importedAt }
    }

    /// 是否存在可撤回的批次
    static func hasUndoableBatch() -> Bool {
        !recentWithin24h().isEmpty
    }

    /// 删除指定批次记录（撤回成功后调用）
    static func remove(id: UUID) {
        var records = loadAll()
        records.removeAll { $0.id == id }
        saveAll(records)
    }

    /// 清除所有批次记录（调试/重置用）
    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 持久化

    private static func loadAll() -> [ImportBatchRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ImportBatchRecord].self, from: data)) ?? []
    }

    private static func saveAll(_ records: [ImportBatchRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
