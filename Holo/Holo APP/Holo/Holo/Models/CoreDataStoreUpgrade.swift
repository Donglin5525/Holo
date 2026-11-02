import Foundation
import SQLite3

/// 只认可「库形态 = 当前模型的某个已发版前身」的向前升级；不放开旧版覆盖新版、删表或未登记的实体变更。
/// 2026-10-31 审计 S1：原「恰好本轮两张知识表」白名单会把多跳升级（如 10-6 构建 59 实体库）
/// 与未来任何一轮忘改白名单的 schema 增量整体拒开；纯加表恰是 CoreData 自动轻量迁移的安全子集，
/// 放宽为「只加不改不删」+ 升级前强制备份，防护语义不变（非加表差异照旧 fail-closed）。
/// 2026-11-02：纯加表规则认不出「老表加过字段」的库——凡跳过某版直接升级、中间那版给已有实体加过
/// 属性的用户会被整库拒开（实证：1.1.2 正式包无 dayEndHour、1.1.3 有，停在 1.1.2 直升 1.1.4 即被拦）。
/// 现按升级登记簿把当前模型逐批倒推回各已发版形态，库指纹与某个形态逐实体完全吻合才放行。
/// 完全吻合即「库 = 当前模型删去若干可选新增项」，轻量迁移只做加法，构造上安全；
/// 登记不全的后果只是那批老库仍被拒（与登记前相同），不会误放行任何未知形态。
nonisolated enum CoreDataStoreUpgrade {
    /// 本轮已知的加表（升级测试夹具用来构造旧模型；门检不再依赖这张清单）
    static let knowledgeEntityNames: Set<String> = [
        "HoloMemoryKnowledgeRevisionMO", "HoloMemoryKnowledgeOperationMO"
    ]

    /// 一批给已有实体新增的属性/关系（只允许可选或带默认值——轻量迁移与 CloudKit 的共同要求）
    struct PropertyBatch: Sendable {
        /// 引入这批新增项的发版（括注同版内的提交先后，细分只为多认出开发期样本库，不影响安全性）
        let release: String
        /// 实体名 → 本批在该实体上新增的属性或关系名
        let additions: [String: Set<String>]
    }

    /// 升级登记簿，按引入先后升序。给已有实体加属性/关系必须同批在此追加一项
    /// （HoloTests 的模型绊线会拦下未登记的变化）；删改属性、改类型属于破坏性变更，不得登记。
    /// 真实旧库验证（2026-11-02，本机 35 个模拟器历史库只读比对）：34 个判定可开——13 一致、3 纯加表、
    /// 18 个落在登记形态（覆盖 1.0.7 起每一版：09-16/17、09-17/18、10-01、10-05、10-08/10、10-14/18 各批）；
    /// 唯一拒开的是 09-09 更早形态（47 实体）。同版内按提交先后细分，只为多认出开发期样本库，不影响安全性。
    static let propertyHistory: [PropertyBatch] = [
        PropertyBatch(release: "1.0.7（目标共创）", additions: [
            "Goal": ["sourceSessionID"]
        ]),
        PropertyBatch(release: "1.0.8", additions: [
            "HoloMatterLink": ["planOrder"]
        ]),
        PropertyBatch(release: "1.0.9（任务分步推进）", additions: [
            "TodoTask": ["activeExecutionRevisionID", "executionSchemaVersion"]
        ]),
        PropertyBatch(release: "1.0.9（习惯暂停、退款与账单附件）", additions: [
            "Habit": ["isPaused", "pausedUntil", "pauseWindowsData"],
            "Transaction": ["refundOfTransactionId", "attachments"]
        ]),
        PropertyBatch(release: "1.1.0（今日减负）", additions: [
            "ChatMessage": ["todayReliefJSON"]
        ]),
        PropertyBatch(release: "1.1.0（任务分类）", additions: [
            "TodoTask": ["importanceRaw", "urgencyModeRaw"]
        ]),
        PropertyBatch(release: "1.1.1", additions: [
            "CheckItem": ["isWaiting", "reviewRemindAt", "waitHintsJSON", "waitNote"],
            "TodoList": ["isEphemeral"],
            "Topic": ["categoryDefinition"]
        ]),
        PropertyBatch(release: "1.1.3", additions: [
            "Habit": ["dayEndHour", "dayEndMinute", "dailyConfirmations"],
            "Thought": ["appearanceRaw"],
            "ThoughtTag": ["excludeFromAI"],
            "GoalPlanRevisionMO": ["planPayloadJSON", "baseRevisionID", "operationID", "effectiveFrom"]
        ])
    ]

    /// 第 index 批及其之后全部新增项的并集——删去它们即得「第 index 批引入之前」的形态
    static func additions(since index: Int) -> [String: Set<String>] {
        var merged: [String: Set<String>] = [:]
        for batch in propertyHistory[index...] {
            for (entity, names) in batch.additions {
                merged[entity, default: []].formUnion(names)
            }
        }
        return merged
    }

    enum Verdict: Equatable {
        /// 指纹完全一致
        case identical
        /// 只多了表（2026-10-31 S1 口径）
        case additiveTables
        /// 库是登记簿里某个已发版形态（可再叠加之后的加表）
        case registered(release: String)
        /// 未知差异、降级、改表——拒开
        case rejected
    }

    /// 库的每个实体都在形态里且哈希相同（形态可多出库没有的表）
    static func storeMatches(_ store: [String: Data], shape: [String: Data]) -> Bool {
        store.allSatisfy { shape[$0.key] == $0.value }
    }

    /// 判定：一致 / 纯加表 / 登记过的历史形态 / 拒绝。
    /// legacyShape(i) 返回「第 i 批引入之前」的模型指纹，只在前两档不成立时按需计算（升级那次才付出建模成本）。
    static func verdict(
        store: [String: Data],
        model: [String: Data],
        legacyShape: (Int) -> [String: Data]
    ) -> Verdict {
        if store == model { return .identical }
        if isAdditiveUpgrade(store: store, model: model) { return .additiveTables }
        for index in propertyHistory.indices.reversed() where storeMatches(store, shape: legacyShape(index)) {
            return .registered(release: propertyHistory[index].release)
        }
        return .rejected
    }

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
