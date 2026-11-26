import Foundation
import CoreData
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
        ]),
        PropertyBatch(release: "1.1.6（习惯描述）", additions: [
            "Habit": ["habitDescription"]
        ]),
        PropertyBatch(release: "1.1.8（信用卡还款提醒）", additions: [
            "Account": ["dueReminderEnabled", "dueReminderLeadDays"]
        ]),
        PropertyBatch(release: "习惯累计与文件夹", additions: [
            "Habit": ["folderID", "prefersQuantityInput", "cumulativeStartDay"]
        ]),
        PropertyBatch(release: "习惯文件夹外观", additions: [
            "HabitFolder": ["emoji"]
        ]),
        PropertyBatch(release: "固定支出订阅提醒与自定义外观", additions: [
            "SpendingProject": ["reminderEnabled", "reminderLeadDays", "icon"]
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
        /// 未在手工登记簿中，但经 SQLite 真实表/列只读核验确认为严格纯增量加字段升级（2026-11-26 根治「漏登记卡死用户」）
        case additiveColumns
        /// 未知差异、降级、删表、删列或改类型——拒开
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

    // MARK: - SQLite 真实列级纯增量核验（2026-11-26：不因漏填手工白名单卡死用户，仍严格拦删表/删列/改类型/降级）

    /// 只读核验 SQLite 实际列结构：老库所有表和列都完整存在于新模型且存储亲和类型兼容，
    /// 且新模型多出的属性/关系全部为可选或带默认值，才判定为安全的向前纯增量升级。
    /// 优先用普通只读模式查询实时 WAL；若因干净关闭无 -shm 导致只读查询失败且确认无待合并 WAL，
    /// 再退回 immutable=1 只读快照复核（并在查询后再核验一次 WAL 状态）。
    static func isSQLiteAdditiveSchemaUpgrade(
        at storeURL: URL,
        storeHashes: [String: Data],
        model: NSManagedObjectModel
    ) -> Bool {
        let modelEntities = model.entitiesByName
        // 1. 禁止删表：老库中每一个实体必须在新模型中存在
        guard Set(storeHashes.keys).isSubset(of: Set(modelEntities.keys)) else { return false }

        let modelHashes = model.entityVersionHashesByName
        let changedEntityNames = storeHashes.keys.filter { modelHashes[$0] != storeHashes[$0] }
        guard !changedEntityNames.isEmpty else { return false }

        switch inspectSQLiteAdditiveSchema(
            at: storeURL,
            changedEntityNames: changedEntityNames,
            modelEntities: modelEntities,
            immutable: false
        ) {
        case .additiveSafe:
            return true
        case .incompatible:
            return false
        case .unreadable:
            // 普通只读查询失败（常见于干净关闭且无 -shm 文件）时，确认无待合并 WAL 再用 immutable 快照读
            guard !storeHasPendingWAL(at: storeURL) else { return false }
            let fallback = inspectSQLiteAdditiveSchema(
                at: storeURL,
                changedEntityNames: changedEntityNames,
                modelEntities: modelEntities,
                immutable: true
            )
            guard !storeHasPendingWAL(at: storeURL) else { return false }
            return fallback == .additiveSafe
        }
    }

    private enum SQLiteSchemaInspectionResult: Equatable {
        case additiveSafe
        case incompatible
        case unreadable
    }

    private static func inspectSQLiteAdditiveSchema(
        at storeURL: URL,
        changedEntityNames: [String],
        modelEntities: [String: NSEntityDescription],
        immutable: Bool
    ) -> SQLiteSchemaInspectionResult {
        guard let database = openReadOnlySQLite(at: storeURL, immutable: immutable) else {
            return .unreadable
        }
        defer { sqlite3_close(database) }

        for entityName in changedEntityNames {
            guard let entity = modelEntities[entityName] else { return .incompatible }
            let tableName = "Z" + entityName.uppercased()
            guard let existingColumns = readSQLiteTableColumns(tableName: tableName, from: database) else {
                return .unreadable
            }
            guard !existingColumns.isEmpty else {
                return .incompatible
            }

            let expected = expectedSQLiteColumns(for: entity)

            // 2. 无删列、无降级、无改类型：老表每一个业务列（非 Z_ 系统列）必须在新模型列集合中且类型兼容
            for (colName, existingType) in existingColumns {
                if colName.hasPrefix("Z_") { continue }
                guard let expectedSpec = expected[colName] else {
                    // 老库多出新模型没有的列 = 删字段或旧版 App 降级打开新版库 → 严格拒绝
                    return .incompatible
                }
                if existingType != expectedSpec.columnType {
                    // 列存储类型变化（含 Date↔Double / Decimal↔Double / TEXT↔INTEGER 等）→ 严格拒绝
                    return .incompatible
                }
                // 若新模型收紧为非可选且无默认值，老库该列存在 NULL 时轻量迁移会失败 → 严格拒绝
                if !expectedSpec.isAdditiveSafe {
                    guard let hasNull = tableColumnHasNull(tableName: tableName, columnName: colName, in: database) else {
                        return .unreadable
                    }
                    if hasNull {
                        return .incompatible
                    }
                }
            }

            // 3. 新增字段必须全部满足轻量迁移与 CloudKit 安全条件（可选或带默认值）
            for (colName, expectedSpec) in expected where existingColumns[colName] == nil {
                if !expectedSpec.isAdditiveSafe {
                    return .incompatible
                }
            }
        }

        // 4. 多对多联合表防删/防降级：老库中每一个 Z_<实体号><关系名> 联合表对应关系必须仍存在于新模型中
        guard let joinTables = readSQLiteManyToManyJoinTables(from: database) else {
            return .unreadable
        }
        if !joinTables.isEmpty {
            let modelManyToManyNames = Set(
                modelEntities.values.flatMap { entity in
                    entity.relationshipsByName.values
                        .filter { !$0.isTransient && $0.isToMany && ($0.inverseRelationship?.isToMany ?? false) }
                        .map { $0.name.uppercased() }
                }
            )
            for relSuffix in joinTables where !modelManyToManyNames.contains(relSuffix) {
                return .incompatible
            }
        }
        return .additiveSafe
    }

    private static func storeHasPendingWAL(at url: URL) -> Bool {
        let walPath = url.path + "-wal"
        guard FileManager.default.fileExists(atPath: walPath) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attrs[.size] as? NSNumber else { return true }
        return size.uint64Value > 0
    }

    private struct ExpectedColumnSpec {
        let columnType: SQLiteColumnType
        let isAdditiveSafe: Bool
    }

    /// 精确匹配 CoreData SQLite 声明类型，拦截 Date↔Double、Decimal↔Double 等同亲和类破坏性变更
    private enum SQLiteColumnType: Equatable {
        case integer
        case float
        case timestamp
        case decimal
        case text
        case blob
    }

    private static func normalizeColumnType(_ rawType: String) -> SQLiteColumnType {
        let upper = rawType.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("TIMESTAMP") { return .timestamp }
        if upper.contains("DECIMAL") { return .decimal }
        if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT") || upper.contains("VARCHAR") {
            return .text
        }
        if upper.contains("BLOB") || upper.isEmpty { return .blob }
        // FLOAT / DOUBLE / REAL / NUMERIC
        return .float
    }

    private static func expectedSQLiteColumns(for entity: NSEntityDescription) -> [String: ExpectedColumnSpec] {
        var result: [String: ExpectedColumnSpec] = [:]
        // 含父实体的全部持久化属性
        for (_, attr) in entity.attributesByName where !attr.isTransient {
            let colName = "Z" + attr.name.uppercased()
            let columnType: SQLiteColumnType
            switch attr.attributeType {
            case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType, .booleanAttributeType:
                columnType = .integer
            case .doubleAttributeType, .floatAttributeType:
                columnType = .float
            case .dateAttributeType:
                columnType = .timestamp
            case .decimalAttributeType:
                columnType = .decimal
            case .stringAttributeType, .URIAttributeType:
                columnType = .text
            case .binaryDataAttributeType, .UUIDAttributeType, .transformableAttributeType, .objectIDAttributeType:
                columnType = .blob
            default:
                columnType = .blob
            }
            let safe = attr.isOptional || attr.defaultValue != nil
            result[colName] = ExpectedColumnSpec(columnType: columnType, isAdditiveSafe: safe)
        }
        // to-one 关系对应外键列（INTEGER）
        for (_, rel) in entity.relationshipsByName where !rel.isTransient && !rel.isToMany {
            let colName = "Z" + rel.name.uppercased()
            result[colName] = ExpectedColumnSpec(columnType: .integer, isAdditiveSafe: rel.isOptional)
        }
        return result
    }

    private static func openReadOnlySQLite(at url: URL, immutable: Bool) -> OpaquePointer? {
        let path = immutable ? url.absoluteString + "?immutable=1" : url.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        if !immutable {
            sqlite3_busy_timeout(db, 3_000)
        }
        return db
    }

    private static func readSQLiteTableColumns(tableName: String, from database: OpaquePointer) -> [String: SQLiteColumnType]? {
        // 表名仅由字母数字下划线组成，防止 SQL 注入
        guard tableName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(tableName))", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var columns: [String: SQLiteColumnType] = [:]
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
                let colName = String(cString: namePtr).uppercased()
                let typeStr = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                columns[colName] = normalizeColumnType(typeStr)
            } else if rc == SQLITE_DONE {
                break
            } else {
                // 遇到 SQLITE_BUSY / SQLITE_CANTOPEN / SQLITE_READONLY 等 I/O 错误时返回 nil，触发外层 immutable 兜底
                return nil
            }
        }
        return columns
    }

    /// 检查表内某列是否存在 NULL 值（nil 表示查询失败，交外层走 immutable 兜底）
    private static func tableColumnHasNull(tableName: String, columnName: String, in database: OpaquePointer) -> Bool? {
        guard tableName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              columnName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM \(tableName) WHERE \(columnName) IS NULL LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        return nil
    }

    /// 读取老库中所有 CoreData 多对多联合表（形如 Z_48TAGS）的关系名后缀（如 TAGS）
    private static func readSQLiteManyToManyJoinTables(from database: OpaquePointer) -> [String]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%' ESCAPE '\\'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var suffixes: [String] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
                let tableName = String(cString: namePtr).uppercased()
                // CoreData 多对多联合表命名固定为 Z_<数字><关系名大写>（排除 Z_PRIMARYKEY / Z_METADATA / Z_MODELCACHE）
                guard tableName.hasPrefix("Z_") else { continue }
                let afterPrefix = tableName.dropFirst(2)
                let digits = afterPrefix.prefix(while: { $0.isNumber })
                let relSuffix = afterPrefix.dropFirst(digits.count)
                if !digits.isEmpty, !relSuffix.isEmpty, relSuffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    suffixes.append(String(relSuffix))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                return nil
            }
        }
        return suffixes
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
        var step: Int32 = SQLITE_BUSY
        for attempt in 0..<6 {
            step = sqlite3_backup_step(backup, -1)
            if step == SQLITE_DONE || (step != SQLITE_BUSY && step != SQLITE_LOCKED) {
                break
            }
            if attempt < 5 {
                sqlite3_sleep(150)
            }
        }
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
