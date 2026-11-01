import Foundation
import SQLite3

/// 只认可纯加表（additive）的向前增量升级；不放开旧版覆盖新版、删表或已有实体变更。
/// 2026-10-31 审计 S1：原「恰好本轮两张知识表」白名单会把多跳升级（如 10-6 构建 59 实体库）
/// 与未来任何一轮忘改白名单的 schema 增量整体拒开；纯加表恰是 CoreData 自动轻量迁移的安全子集，
/// 放宽为「只加不改不删」+ 升级前强制备份，防护语义不变（非加表差异照旧 fail-closed）。
nonisolated enum CoreDataStoreUpgrade {
    /// 本轮已知的加表（升级测试夹具用来构造旧模型；门检不再依赖这张清单）
    static let knowledgeEntityNames: Set<String> = [
        "HoloMemoryKnowledgeRevisionMO", "HoloMemoryKnowledgeOperationMO"
    ]

    /// 纯加表判定：库中实体全部仍在且哈希不变，且模型确有新表。改表/删表一律不放行。
    static func isAdditiveUpgrade(store: [String: Data], model: [String: Data]) -> Bool {
        let additions = Set(model.keys).subtracting(store.keys)
        return !additions.isEmpty
            && Set(store.keys).isSubset(of: Set(model.keys))
            && store.allSatisfy { model[$0.key] == $0.value }
    }

    /// SQLite backup API 包含 WAL 中已提交的事务，不用文件拷贝冒充一致性快照。
    /// 备份失败就拒绝升级；不写原库业务数据，绝不移动、清空或覆盖原库。
    static func makeBackup(of storeURL: URL) throws -> URL {
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("StoreUpgradeBackups", isDirectory: true)
            .appendingPathComponent("pre-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(storeURL.lastPathComponent)
        var sourceDB: OpaquePointer?
        var backupDB: OpaquePointer?
        // 允许 SQLite 创建必需的 WAL/SHM 锁文件，否则干净关闭后的库无法备份。
        // 连接启用 query_only，代码只调用备份 API，不执行原库的数据写入。
        guard sqlite3_open_v2(storeURL.path, &sourceDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let sourceDB else {
            let error = backupError(sourceDB)
            sqlite3_close(sourceDB)
            throw error
        }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_exec(sourceDB, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw backupError(sourceDB)
        }
        guard sqlite3_open_v2(destination.path, &backupDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backupDB else {
            let error = backupError(backupDB)
            sqlite3_close(backupDB)
            throw error
        }
        defer { sqlite3_close(backupDB) }
        sqlite3_busy_timeout(sourceDB, 3_000)
        sqlite3_busy_timeout(backupDB, 3_000)
        guard let backup = sqlite3_backup_init(backupDB, "main", sourceDB, "main") else {
            throw backupError(backupDB)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw backupError(backupDB) }

        // Core Data 外置 BLOB 也随快照保留；应用自己管理的附件目录不在升级中搬动。
        let supportName = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
        let support = storeURL.deletingLastPathComponent().appendingPathComponent(supportName)
        if FileManager.default.fileExists(atPath: support.path) {
            try FileManager.default.copyItem(at: support, to: directory.appendingPathComponent(supportName))
        }
        return destination
    }

    private static func backupError(_ database: OpaquePointer?) -> NSError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 无法打开"
        return NSError(domain: "HoloStoreUpgrade", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "数据库升级前的安全备份未能完成，原始数据已保留。\(detail)"
        ])
    }
}
