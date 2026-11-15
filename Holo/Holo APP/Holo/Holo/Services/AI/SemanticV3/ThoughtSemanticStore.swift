//
//  ThoughtSemanticStore.swift
//  Holo
//
//  本机语义元数据库（语义图谱 V3 Phase 2，方案 §7.4）
//
//  SQLite 真身：向量（Float16 blob）、任务队列、manifest。
//  不进 Core Data / CloudKit；目录 Application Support/ThoughtSemanticV3/，
//  索引缓存文件同目录。错误只存枚举 code，不存服务端 message 或正文片段。
//
//  Phase 2 范围：semantic_item / semantic_job / semantic_manifest 完整 API；
//  topic_centroid / relation_candidate / candidate_cluster 建表先行（schema
//  一次到位避免后续迁移），消费方 API 在 Phase 3/5 落地。
//

import Foundation
import CryptoKit
import SQLite3
import os

/// SQLITE_TRANSIENT 是 C 宏，Swift 侧需手工等价定义
nonisolated(unsafe) private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ThoughtSemanticStore {

    enum StoreError: Error, Equatable {
        case openFailed(code: Int32)
        case sqlFailed(code: Int32, sql: String)
        case schemaVersionUnsupported(Int)
        case jobNotFound(UUID)
        /// R03（2026-10-04 体检）：维度与向量元素数不一致 / 非正维度，写入前拒绝落库
        case invalidVector(dimension: Int, vectorCount: Int)
    }

    private nonisolated static let logger = Logger(subsystem: "com.holo.app", category: "ThoughtSemanticStore")

    // MARK: - 行类型

    struct SemanticItem: Codable, Equatable {
        var id: UUID              // = thoughtID（一条想法一个槽位）
        var contentHash: String
        var modelVersion: String
        var dimension: Int
        var vectorKey: UInt64
        var state: String         // active / tombstoned
        var priority: Int
        var lastAccessedAt: Date?
        var updatedAt: Date
    }

    struct SemanticJob: Codable, Equatable {
        var id: UUID
        var thoughtID: UUID
        var contentHash: String
        var kind: String          // embed（Phase 3 起 relate/name/summary 由各自入口管）
        var priority: Int
        var state: String         // pending / running / done / failed_terminal / cancelled
        var attemptCount: Int
        var nextAttemptAt: Date?
        var consentGeneration: Int64
        var lastErrorCode: String?
    }

    /// 主题摘要行（AI 派生，只存本机；basisRevision=生成时的 topicRevision）
    struct TopicSummaryRecord: Codable, Equatable {
        var topicID: UUID
        var modelVersion: String
        var basisRevision: Int64
        var summary: String
        var viewpointsJSON: String   // [{ref: thoughtUUIDString, quote, range:[a,b]}]
        var updatedAt: Date
    }

    /// 候选簇行（新脉络建议，方案 §4.4；state: suggested/ready/snoozed/converted/rejected）
    struct ClusterRecord: Codable, Equatable {
        var id: String
        var fingerprint: String
        var memberIDs: [UUID]
        var state: String
        var cohesion: Float
        var name: String?            // topic-name 端点建议名（用户改名后由 titleSource 表达）
        var firstSeenAt: Date
        var lastSeenAt: Date
        var dismissedUntil: Date?
    }

    struct Manifest: Codable, Equatable {
        var schemaVersion: Int
        var activeModelVersion: String
        var buildingModelVersion: String?
        var indexGeneration: Int
        var nextVectorKey: UInt64
        var lastCompactedAt: Date?
    }

    // MARK: - 脉络核对行类型（W2，2026-11-16 方案 §6 C3）

    /// 核对成功的有界判定：双侧引用位置与简短说明。ref 在落库前已映射回本机
    /// thoughtID——调用与显示句柄只从本机 source 映射绑定，不从模型响应字符串拼接（§6 C3）。
    struct FollowupEvidenceRecord: Codable, Equatable {
        var thoughtID: UUID
        var windowRef: String        // 请求内窗口短编号（证据核对用）
        var windowOffsetUTF16: Int   // 窗口在脱敏全文中的 UTF-16 起点（Source 行可重建）
        var quote: String            // 1–120 UTF-16 逐字引用
        var rangeUTF16: [Int]        // 窗口内半开区间 [start, end)
    }

    struct FollowupDecisionRecord: Codable, Equatable {
        var otherThoughtID: UUID
        var relation: String         // continues/adds_example/contrasts/revises/none/insufficient
        var reason: String?          // 成立关系 1–100 UTF-16；none/insufficient 为 nil
        var anchorEvidence: FollowupEvidenceRecord?
        var otherEvidence: FollowupEvidenceRecord?
    }

    /// 脉络核对任务与结果行（主键 taskKey）。持久状态机：
    /// pending → running → verified / no_result / waiting / failed（§6 C3）；
    /// cancelled 为撤权/版本变更/范围退出的终态（不重试、不算凭证）。
    struct FollowupResultRecord: Equatable {
        enum State: String {
            case pending, running
            case verified, noResult = "no_result"
            case waiting, failed, cancelled
            var isTerminal: Bool { self == .verified || self == .noResult || self == .failed || self == .cancelled }
            /// verified/no_result 皆终态不重算（§5 B2）；failed 仅在新策略版本下另起 taskKey。
            var isCompletionReceipt: Bool { self == .verified || self == .noResult }
        }
        var taskKey: String
        var scopeID: UUID
        var anchorID: UUID
        var state: State
        var policyVersion: String
        var operationID: String      // 重启重试复用同一 operationId（§6 C2 末条）
        var runDeadline: Date?       // 运行时限：超时的 running 由下次领取回收
        var nextAttemptAt: Date?
        var attemptCount: Int
        var startedDay: String?      // 首次尝试的设备日（yyyy-MM-dd，本地时区）
        var createdAt: Date
        var verifiedAt: Date?
        var lastErrorCode: String?
        var decisions: [FollowupDecisionRecord]   // 成功后有界判定数组
        var threadID: String?                     // 独立 thread local ID（不拿标题当身份，§5 B2）
        var threadTitle: String?
        var threadQuestion: String?
        var threadMemberIDs: [UUID]
    }

    /// 请求输入映射行（主键 taskKey × thoughtID）：记录该请求的**全部输入**
    /// （含最终没进入卡片的输入）；结果有效性与清理以所有输入为准（§6 C3）。
    struct FollowupWindowIndex: Codable, Equatable {
        var ref: String
        var offsetUTF16: Int
        var lengthUTF16: Int
    }

    struct FollowupSourceRecord: Equatable {
        var taskKey: String
        var thoughtID: UUID
        var scopeID: UUID
        var contentHash: String       // 冻结的正文 hash（读侧按当前正文核对）
        var redactionVersion: String  // 文本处理版本（窗口按此版本重建脱敏）
        var frozenCreatedAt: Date     // 冻结创建时间（关系方向裁决用，§6 C1）
        var windows: [FollowupWindowIndex]
        var summary: String           // 窗口文本短摘要（卡片可核对片段的本地依据）
    }

    /// 脉络卡隐藏回执（本机 scope × thread local ID）：无内容，
    /// 另存确认展示过的成员 ID 集合用于高重叠压制（§6 C3 / §5 B2）。
    struct FollowupDismissalRecord: Equatable {
        var scopeID: UUID
        var threadID: String
        var memberIDs: [UUID]
        var createdAt: Date
    }

    static let schemaVersion = 1
    static let defaultModelVersion = "text-embedding-v3-v1"   // 与现有 ThoughtEmbeddingStore 一致，迁移可复用

    private var db: OpaquePointer?
    private let directory: URL
    private let dbPath: URL

    /// - Parameter root: 覆盖根目录（测试注入用）；默认 Application Support。
    init(root: URL? = nil) async {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("ThoughtSemanticV3", isDirectory: true)
        dbPath = directory.appendingPathComponent("semantic.sqlite")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - 生命周期

    func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // R14（2026-10-04 体检）：错误码直接取 open 返回值——打开失败后句柄随时释放，
        // 旧写法先 close 再 errcode 查的是已关闭连接，恒得 MISUSE(21)，真实故障原因被掩盖。
        let rc = sqlite3_open_v2(dbPath.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.openFailed(code: rc)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrateIfNeeded()
        // 上一次进程在网络请求中退出，running 没有执行者；冷启动统一回收到队列。
        try exec("UPDATE semantic_job SET state='pending', next_attempt_at=NULL, last_error_code='interrupted' WHERE state='running'")
        // 脉络核对同理（§6 C2 末条）：重启识别未完成尝试置 waiting，复用原 operationId，
        // 仅在既有退避与剩余日额度允许时由下次领取重试——中断的请求可能已在网关计费。
        try exec("UPDATE thought_followup_result SET state='waiting', next_attempt_at=strftime('%s','now'), last_error_code='interrupted' WHERE state='running'")
        try repairLegacyQueue()
    }

    /// 升级旧队列：同一笔记同一阶段只留最新版任务，历史重复记录保留为取消态。
    /// 唯一索引保证以后所有写入口都遵循同一规则，不再重复调用或虚增排队数。
    private func repairLegacyQueue() throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("""
                UPDATE semantic_job SET state='cancelled', last_error_code='duplicate_job',
                    finished_at=strftime('%s','now')
                WHERE state IN ('pending','running') AND rowid NOT IN (
                    SELECT MAX(rowid) FROM semantic_job WHERE state IN ('pending','running')
                    GROUP BY thought_id, kind)
                """)
            let marker = try prepare("SELECT COUNT(*) FROM sqlite_master WHERE name='idx_semantic_job_active_unique'")
            let needsRecovery = sqlite3_step(marker) == SQLITE_ROW && sqlite3_column_int64(marker, 0) == 0
            sqlite3_finalize(marker)
            if needsRecovery {
                // 旧版把任何 429 都挂起一小时；服务与批次修复后仅首次升级立即恢复。
                try exec("UPDATE semantic_job SET next_attempt_at=NULL, last_error_code=NULL WHERE state='pending' AND last_error_code='RATE_LIMITED'")
            }
            try exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_semantic_job_active_unique ON semantic_job(thought_id,kind) WHERE state IN ('pending','running')")
            // 与新版重试策略对齐：恢复旧版模型格式错误留下的长退避，不改额度/网络等待。
            try exec("UPDATE semantic_job SET next_attempt_at=MIN(next_attempt_at,strftime('%s','now')+60) WHERE state='pending' AND last_error_code='MODEL_OUTPUT_INVALID'")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// 「删除设备智能索引」与账户删除共用的销毁入口（方案 §5.3-4/5）：
    /// 销毁向量、任务、候选、簇与缓存文件；不触碰 Thought 原文与 CloudKit。
    func destroyAllData() throws {
        close()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try open()
    }

    /// 主题定义向量缓存，不与想法的向量槽位混用。读取走统一向量契约（R03）。
    func topicProfile(topicID: UUID, contentHash: String) throws -> [Float]? {
        let stmt = try prepare("SELECT dimension, vector_f16 FROM topic_profile WHERE topic_id=?1 AND content_hash=?2 AND model_version=?3", .uuid(topicID), .text(contentHash), .text(Self.defaultModelVersion))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeF16Vector(stmt, dimensionCol: 0, blobCol: 1)
    }
    func saveTopicProfile(topicID: UUID, contentHash: String, vector: [Float]) throws {
        try bindExec("INSERT INTO topic_profile(topic_id,content_hash,model_version,dimension,vector_f16) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(topic_id) DO UPDATE SET content_hash=?2,model_version=?3,dimension=?4,vector_f16=?5", .uuid(topicID), .text(contentHash), .text(Self.defaultModelVersion), .int(Int64(vector.count)), .blob(f16Blob(vector.map(Float16.init))))
    }

    // MARK: - semantic_item

    /// R03（2026-10-04 体检）向量统一读取契约：维度必须为正数，且 BLOB 字节数严格等于
    /// 维度×Float16(2字节)。不满足按坏行返回 nil（调用方隔离等待重建）——禁止按库内
    /// dimension 直接构造数组或索引 Float16 指针（负维度崩溃 / 短 BLOB 越界读）。
    /// 所有向量读取入口必须走这里，不得各自猜测合法长度。
    private func decodeF16Vector(_ stmt: OpaquePointer, dimensionCol: Int32, blobCol: Int32) -> [Float]? {
        let dim = Int(sqlite3_column_int64(stmt, dimensionCol))
        guard dim > 0,
              sqlite3_column_type(stmt, blobCol) == SQLITE_BLOB,
              let blob = sqlite3_column_blob(stmt, blobCol),
              sqlite3_column_bytes(stmt, blobCol) == dim * MemoryLayout<Float16>.size else { return nil }
        let pointer = blob.assumingMemoryBound(to: Float16.self)
        return (0..<dim).map { Float(pointer[$0]) }
    }

    /// 写入/更新向量真身（Float16 blob）。
    func upsertItem(_ item: SemanticItem, vector: [Float16]) throws {
        // R03 写入契约：维度为正数且与向量元素数一致，先校验再落库——读写共享同一份长度契约。
        guard item.dimension > 0, vector.count == item.dimension else {
            throw StoreError.invalidVector(dimension: item.dimension, vectorCount: vector.count)
        }
        try exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }
        try bindExec("""
            INSERT INTO semantic_item(id, thought_id, content_hash, model_version, dimension,
                                      vector_key, state, priority, last_accessed_at, updated_at, vector_f16)
            VALUES(?1,?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
            ON CONFLICT(id) DO UPDATE SET content_hash=?2, model_version=?3, dimension=?4,
                vector_key=?5, state=?6, priority=?7, last_accessed_at=?8, updated_at=?9, vector_f16=?10
            """,
            .uuid(item.id), .text(item.contentHash), .text(item.modelVersion), .int(Int64(item.dimension)),
            .int(Int64(item.vectorKey)), .text(item.state), .int(Int64(item.priority)),
            .date(item.lastAccessedAt), .date(Date()), .blob(f16Blob(vector)))
    }

    /// 批量读取（索引冷启动重建通道）。
    func loadAllActiveVectors(modelVersion: String) throws -> [(id: UUID, key: UInt64, vector: [Float])] {
        let stmt = try prepare("""
            SELECT thought_id, vector_key, dimension, vector_f16 FROM semantic_item
            WHERE state='active' AND model_version=?1
            """, .text(modelVersion))
        defer { sqlite3_finalize(stmt) }
        var rows: [(UUID, UInt64, [Float])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = uuidCol(stmt, 0) else { continue }
            let keyInt = sqlite3_column_int64(stmt, 1)
            guard keyInt >= 0, let vector = decodeF16Vector(stmt, dimensionCol: 2, blobCol: 3) else {
                // 坏行隔离：跳过加载等待管线按原文重建，不终止进程、不动原文
                Self.logger.error("语义索引坏行已隔离待重建：thought=\(id.uuidString, privacy: .public) dim=\(Int(sqlite3_column_int64(stmt, 2)), privacy: .public) blobBytes=\(Int(sqlite3_column_bytes(stmt, 3)), privacy: .public)")
                continue
            }
            rows.append((id, UInt64(keyInt), vector))
        }
        return rows
    }

    /// 单条想法当前版本的有效向量（相关旧想法召回用；版本不符返回 nil）。
    func activeVector(thoughtID: UUID, contentHash: String,
                      modelVersion: String = defaultModelVersion) throws -> [Float]? {
        let stmt = try prepare("""
            SELECT dimension, vector_f16 FROM semantic_item
            WHERE thought_id=?1 AND content_hash=?2 AND model_version=?3 AND state='active'
            """, .uuid(thoughtID), .text(contentHash), .text(modelVersion))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeF16Vector(stmt, dimensionCol: 0, blobCol: 1)
    }

    /// 相同 contentHash/modelVersion 已完成则跳过（管线第 2 步版本判定）。
    func hasActiveItem(thoughtID: UUID, contentHash: String, modelVersion: String) throws -> Bool {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM semantic_item
            WHERE thought_id=?1 AND content_hash=?2 AND model_version=?3 AND state='active'
            """, .uuid(thoughtID), .text(contentHash), .text(modelVersion))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    /// 读取单条想法的当前向量（Float32；无/墓碑返回 nil）——候选引擎 centroid 用。
    func loadVector(thoughtID: UUID) throws -> [Float]? {
        let stmt = try prepare("""
            SELECT dimension, vector_f16 FROM semantic_item
            WHERE thought_id=?1 AND state='active'
            """, .uuid(thoughtID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeF16Vector(stmt, dimensionCol: 0, blobCol: 1)
    }

    /// 记录一次影子关联决策（relation_candidate 表，Phase 3 shadow 主产物）。
    /// verifierQuote（P0-B）：模型返回的逐字证据原文片段，随记录落库，
    /// 供 P1「为什么归在这里」回源展示——脱敏坐标不直接用于原文高亮。
    func recordRelationCandidate(thoughtID: UUID,
                                 topicID: UUID,
                                 contentHash: String,
                                 scoreFeatures: String,
                                 verifierResult: String,
                                 state: String,
                                 engineVersion: String,
                                 expiryDays: Int,
                                 verifierQuote: String? = nil) throws {
        let expires = Date().addingTimeInterval(Double(expiryDays) * 86_400)
        try bindExec("""
            INSERT INTO relation_candidate(thought_id, topic_id, content_hash, score_features,
                                           verifier_result, state, engine_version, expires_at, verifier_quote)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
            ON CONFLICT(thought_id, topic_id) DO UPDATE SET content_hash=?3, score_features=?4,
                verifier_result=?5, state=?6, engine_version=?7, expires_at=?8, verifier_quote=?9
            """,
            .uuid(thoughtID), .uuid(topicID), .text(contentHash), .text(scoreFeatures),
            .text(verifierResult), .text(state), .text(engineVersion), .date(expires), .text(verifierQuote))
    }

    /// 该想法此正文版本是否已有 relate 记录。传入目录版本后统一补齐类别理解版本，
    /// 与执行器的回执保持同一口径，避免有 brief 的笔记成功后仍反复入队。
    /// W1（2026-11-16 方案 §4 A2）：类别规则层激活（同一策略函数 categoryRulesCoverage
    /// 裁决）时按 v4 版本键判重——v4 回执与 v3 回执两个版本空间互不可见，
    /// 同版本持久化的空结果（哨兵行）同样算完成态，不重复入队。
    func hasRelationRecord(thoughtID: UUID, contentHash: String, evaluationVersion: String? = nil) throws -> Bool {
        let currentVersion = try evaluationVersion.map { try relationEvaluationVersion(catalogVersion: $0) }
        if let catalogVersion = currentVersion,
           let mode = ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: thoughtID) {
            let v4Version = Self.schema4EvaluationVersionKey(
                catalogVersion: catalogVersion, mode: mode.rawValue, contentHash: contentHash)
            let v4Stmt = try prepare("""
                SELECT COUNT(*) FROM relation_candidate
                WHERE thought_id=?1 AND content_hash=?2 AND expires_at > ?3 AND engine_version=?4
                """, .uuid(thoughtID), .text(contentHash), .date(Date()), .text(v4Version))
            defer { sqlite3_finalize(v4Stmt) }
            guard sqlite3_step(v4Stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int64(v4Stmt, 0) > 0
        }
        let stmt = try prepare("""
            SELECT COUNT(*) FROM relation_candidate
            WHERE thought_id=?1 AND content_hash=?2 AND expires_at > ?3
                AND (?4 IS NULL OR engine_version=?4)
            """, .uuid(thoughtID), .text(contentHash), .date(Date()), .text(currentVersion))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    /// W1 统一评估版本键（规范编码）：schema + policy + effective candidate scope + contentHash。
    /// · schema/policy：固定前缀 thought_semantic_v4:<mode>（shadow 与 live 版本空间分隔）；
    /// · effective candidate scope：catalogVersion（目录指纹 + brief 版本键）参与哈希，
    ///   它枚举了召回与判据的全部输入；
    /// · contentHash：目标正文版本参与哈希。
    /// v3 的 relationEvaluationVersion 语义不动：键前缀天然分隔两个空间，v4 回执
    /// 绝不污染 v3 判重，反之亦然。队列（hasRelationRecord）、评估回执与去重共用本函数。
    nonisolated static func schema4EvaluationVersionKey(catalogVersion: String, mode: String, contentHash: String) -> String {
        let digest = SHA256.hash(data: Data((catalogVersion + "\u{1f}" + mode + "\u{1f}" + contentHash).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "thought_semantic_v4:" + mode + ":" + digest
    }

    /// tombstone 删除（物理清理由 compact）。
    func tombstoneItem(thoughtID: UUID) throws {
        try bindExec("UPDATE semantic_item SET state='tombstoned', updated_at=?2 WHERE thought_id=?1",
                     .uuid(thoughtID), .date(Date()))
    }

    // MARK: - topic_summary（主题摘要，方案 §4.5；AI 派生只存本机）

    /// 保存/覆盖主题摘要。viewpointsJSON 是已编码的观点数组（ref=想法 UUID 字符串）。
    func saveTopicSummary(topicID: UUID,
                          modelVersion: String,
                          basisRevision: Int64,
                          summary: String,
                          viewpointsJSON: String) throws {
        try bindExec("""
            INSERT INTO topic_summary(topic_id, model_version, basis_revision, summary, viewpoints_json, updated_at)
            VALUES(?1,?2,?3,?4,?5,?6)
            ON CONFLICT(topic_id) DO UPDATE SET model_version=?2, basis_revision=?3,
                summary=?4, viewpoints_json=?5, updated_at=?6
            """,
            .uuid(topicID), .text(modelVersion), .int64(basisRevision), .text(summary),
            .text(viewpointsJSON), .date(Date()))
    }

    func loadTopicSummary(topicID: UUID) throws -> TopicSummaryRecord? {
        let stmt = try prepare("""
            SELECT model_version, basis_revision, summary, viewpoints_json, updated_at
            FROM topic_summary WHERE topic_id=?1
            """, .uuid(topicID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return TopicSummaryRecord(
            topicID: topicID,
            modelVersion: String(cString: sqlite3_column_text(stmt, 0)),
            basisRevision: sqlite3_column_int64(stmt, 1),
            summary: String(cString: sqlite3_column_text(stmt, 2)),
            viewpointsJSON: String(cString: sqlite3_column_text(stmt, 3)),
            updatedAt: dateCol(stmt, 4) ?? Date())
    }

    /// 成员变化使摘要失效（basisRevision 落后）时由调用方判断；此处仅提供按删除清理。
    func deleteTopicSummary(topicID: UUID) throws {
        try bindExec("DELETE FROM topic_summary WHERE topic_id=?1", .uuid(topicID))
    }

    // MARK: - category_brief（类别理解，2026-10-12 主题双通道·零打扰；AI 派生只存本机）

    struct CategoryBriefRecord: Equatable {
        var topicID: UUID
        var version: Int
        var definition: String
        var exclusions: [String]
        var basisMemberCount: Int
        var basisRemovalCount: Int
        var updatedAt: Date

        var exclusionsJSON: String {
            (try? JSONEncoder().encode(exclusions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
    }

    /// 幂等落库一版 brief（version 由调用方递增）。
    func saveCategoryBrief(_ record: CategoryBriefRecord) throws {
        try bindExec("""
            INSERT INTO category_brief(topic_id, version, definition, exclusions_json,
                                       basis_member_count, basis_removal_count, updated_at)
            VALUES(?1,?2,?3,?4,?5,?6,?7)
            ON CONFLICT(topic_id) DO UPDATE SET version=?2, definition=?3, exclusions_json=?4,
                basis_member_count=?5, basis_removal_count=?6, updated_at=?7
            """,
            .uuid(record.topicID), .int64(Int64(record.version)), .text(record.definition),
            .text(record.exclusionsJSON), .int64(Int64(record.basisMemberCount)),
            .int64(Int64(record.basisRemovalCount)), .date(record.updatedAt))
    }

    func loadCategoryBrief(topicID: UUID) throws -> CategoryBriefRecord? {
        let stmt = try prepare("""
            SELECT version, definition, exclusions_json, basis_member_count, basis_removal_count, updated_at
            FROM category_brief WHERE topic_id=?1
            """, .uuid(topicID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let exclusionsData = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
        let exclusions = (try? JSONDecoder().decode([String].self, from: exclusionsData)) ?? []
        return CategoryBriefRecord(
            topicID: topicID,
            version: Int(sqlite3_column_int64(stmt, 0)),
            definition: String(cString: sqlite3_column_text(stmt, 1)),
            exclusions: exclusions,
            basisMemberCount: Int(sqlite3_column_int64(stmt, 3)),
            basisRemovalCount: Int(sqlite3_column_int64(stmt, 4)),
            updatedAt: dateCol(stmt, 5) ?? Date())
    }

    /// 全部 brief 的版本键（topicID:version），供关联重评指纹拼接——brief 升版自然重评。
    func allCategoryBriefVersionKeys() throws -> [String] {
        let stmt = try prepare("SELECT topic_id, version FROM category_brief")
        defer { sqlite3_finalize(stmt) }
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = uuidCol(stmt, 0) {
                keys.append("\(id.uuidString):\(sqlite3_column_int64(stmt, 1))")
            }
        }
        return keys.sorted()
    }

    /// 入队去重与整理回执共用完整指纹；沿用既有格式，可直接识别历史成功记录。
    func relationEvaluationVersion(catalogVersion: String) throws -> String {
        let briefKeys = try allCategoryBriefVersionKeys()
        return briefKeys.isEmpty ? catalogVersion : catalogVersion + ":brief=" + briefKeys.joined(separator: "|")
    }

    func deleteCategoryBrief(topicID: UUID) throws {
        try bindExec("DELETE FROM category_brief WHERE topic_id=?1", .uuid(topicID))
    }

    // MARK: - category_rules_diagnostic（W1 类别规则层诊断，只存 id 与原因码，不含正文）

    /// 影子评测诊断（W1，2026-11-16 方案 §4 A2/W1）：schema 4 路径的可观测产物，
    /// 仅记录稳定 ID、正文哈希与原因码（category_definition_too_long /
    /// category_definition_unreadable / schema4_server_rejected 等），shadow 与 live
    /// 模式共用；不写任何正式关系。同 (thought, topic, reason) 幂等覆盖。
    func recordCategoryRulesDiagnostic(thoughtID: UUID,
                                       topicID: UUID,
                                       contentHash: String,
                                       reason: String,
                                       mode: String) throws {
        try bindExec("""
            INSERT INTO category_rules_diagnostic(thought_id, topic_id, content_hash, reason, mode, created_at)
            VALUES(?1,?2,?3,?4,?5,?6)
            ON CONFLICT(thought_id, topic_id, reason) DO UPDATE SET content_hash=?3, mode=?5, created_at=?6
            """,
            .uuid(thoughtID), .uuid(topicID), .text(contentHash), .text(reason), .text(mode), .date(Date()))
    }

    /// 读回一条想法的全部类别规则层诊断（测试与设置诊断用）。
    func categoryRulesDiagnostics(thoughtID: UUID) throws -> [(topicID: UUID, reason: String, mode: String, createdAt: Date)] {
        let stmt = try prepare("""
            SELECT topic_id, reason, mode, created_at FROM category_rules_diagnostic
            WHERE thought_id=?1 ORDER BY created_at DESC
            """, .uuid(thoughtID))
        defer { sqlite3_finalize(stmt) }
        var rows: [(UUID, String, String, Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let topicID = uuidCol(stmt, 0),
                  let reason = textCol(stmt, 1),
                  let mode = textCol(stmt, 2) else { continue }
            rows.append((topicID, reason, mode, dateCol(stmt, 3) ?? Date()))
        }
        return rows
    }

    /// 类别理解统计（设置页状态卡）：已代写主题数 + 最近更新时间。
    func categoryBriefStats() throws -> (count: Int, lastUpdatedAt: Date?) {
        let stmt = try prepare("SELECT COUNT(*), MAX(updated_at) FROM category_brief")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil) }
        return (Int(sqlite3_column_int64(stmt, 0)), dateCol(stmt, 1))
    }

    /// 单对判定的证据回读（主题徽章「为什么归这里」）：判定值 + 逐字依据 + 引擎版本。
    /// 只有正式归属（same_thread/fits_category）写过逐 pair 行；无行=用户手动或历史归集。
    func loadRelationEvidence(thoughtID: UUID, topicID: UUID) throws -> (relation: String, verifierQuote: String?, engineVersion: String?)? {
        let stmt = try prepare("""
            SELECT verifier_result, verifier_quote, engine_version
            FROM relation_candidate
            WHERE thought_id=?1 AND topic_id=?2 AND verifier_result IN ('same_thread','fits_category')
            ORDER BY expires_at DESC LIMIT 1
            """, .uuid(thoughtID), .uuid(topicID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (String(cString: sqlite3_column_text(stmt, 0)), textCol(stmt, 1), textCol(stmt, 2))
    }

    /// 单对候选记录回读（W1 类别规则层测试与设置诊断）：最近一行的完整状态口径。
    func relationCandidateState(thoughtID: UUID, topicID: UUID) throws -> (verifierResult: String, state: String, scoreFeatures: String?, engineVersion: String?)? {
        let stmt = try prepare("""
            SELECT verifier_result, state, score_features, engine_version
            FROM relation_candidate
            WHERE thought_id=?1 AND topic_id=?2
            ORDER BY expires_at DESC LIMIT 1
            """, .uuid(thoughtID), .uuid(topicID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                textCol(stmt, 2),
                textCol(stmt, 3))
    }

    // MARK: - candidate_cluster（新脉络建议，方案 §4.4；AI 派生只存本机）

    /// 幂等落库一簇。dismissedUntil 传 nil 表示清除冷却；name 传 nil 不覆盖已有名。
    func upsertCluster(id: String,
                       fingerprint: String,
                       memberIDs: [UUID],
                       state: String,
                       cohesion: Float,
                       name: String?,
                       dismissedUntil: Date?) throws {
        let membersJSON = (try? JSONEncoder().encode(memberIDs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let now = Date()
        if name != nil {
            try bindExec("""
                INSERT INTO candidate_cluster(id, fingerprint, centroid_key, member_ids, state,
                                             cohesion, name, first_seen_at, last_seen_at, dismissed_until)
                VALUES(?1,?2,NULL,?3,?4,?5,?6,?7,?7,?8)
                ON CONFLICT(fingerprint) DO UPDATE SET member_ids=?3, state=?4, cohesion=?5,
                    name=?6, last_seen_at=?7, dismissed_until=?8
                """,
                .text(id), .text(fingerprint), .text(membersJSON), .text(state),
                .double(Double(cohesion)), .text(name), .date(now), .date(dismissedUntil))
        } else {
            try bindExec("""
                INSERT INTO candidate_cluster(id, fingerprint, centroid_key, member_ids, state,
                                             cohesion, name, first_seen_at, last_seen_at, dismissed_until)
                VALUES(?1,?2,NULL,?3,?4,?5,NULL,?6,?6,?7)
                ON CONFLICT(fingerprint) DO UPDATE SET member_ids=?3, state=?4, cohesion=?5,
                    last_seen_at=?6, dismissed_until=?7
                """,
                .text(id), .text(fingerprint), .text(membersJSON), .text(state),
                .double(Double(cohesion)), .date(now), .date(dismissedUntil))
        }
    }

    /// 仅更新建议名（命名回填；不触其他字段）。
    func updateClusterName(fingerprint: String, name: String) throws {
        try bindExec("UPDATE candidate_cluster SET name=?2 WHERE fingerprint=?1",
                     .text(fingerprint), .text(name))
    }

    private func clusterRow(_ stmt: OpaquePointer) -> ClusterRecord? {
        guard let idData = sqlite3_column_text(stmt, 0) else { return nil }
        guard let fpData = sqlite3_column_text(stmt, 1) else { return nil }
        guard let membersData = sqlite3_column_text(stmt, 2) else { return nil }
        let members = (try? JSONDecoder().decode([UUID].self, from: Data(String(cString: membersData).utf8))) ?? []
        let name = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        return ClusterRecord(
            id: String(cString: idData),
            fingerprint: String(cString: fpData),
            memberIDs: members,
            state: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "ready",
            cohesion: Float(sqlite3_column_double(stmt, 4)),
            name: name,
            firstSeenAt: dateCol(stmt, 5) ?? Date(),
            lastSeenAt: dateCol(stmt, 6) ?? Date(),
            dismissedUntil: dateCol(stmt, 7))
    }

    func loadCluster(byFingerprint fingerprint: String) throws -> ClusterRecord? {
        let stmt = try prepare("""
            SELECT id, fingerprint, member_ids, state, cohesion, first_seen_at, last_seen_at, dismissed_until, name
            FROM candidate_cluster WHERE fingerprint=?1
            """, .text(fingerprint))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return clusterRow(stmt)
    }

    func clusters(states: [String]) throws -> [ClusterRecord] {
        let stmt = try prepare("SELECT id, fingerprint, member_ids, state, cohesion, first_seen_at, last_seen_at, dismissed_until, name FROM candidate_cluster ORDER BY cohesion DESC, last_seen_at DESC")
        defer { sqlite3_finalize(stmt) }
        var result: [ClusterRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = clusterRow(stmt), states.contains(row.state) { result.append(row) }
        }
        return result
    }

    /// 当前建议簇（state='suggested'，取内聚度最高一条）。
    func loadSuggestedCluster() throws -> ClusterRecord? {
        let stmt = try prepare("""
            SELECT id, fingerprint, member_ids, state, cohesion, first_seen_at, last_seen_at, dismissed_until, name
            FROM candidate_cluster WHERE state='suggested'
            ORDER BY cohesion DESC, last_seen_at DESC LIMIT 1
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return clusterRow(stmt)
    }

    func item(thoughtID: UUID) throws -> SemanticItem? {
        let stmt = try prepare("""
            SELECT thought_id, content_hash, model_version, dimension, vector_key, state,
                   priority, last_accessed_at, updated_at
            FROM semantic_item WHERE thought_id=?1
            """, .uuid(thoughtID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let rowID = uuidCol(stmt, 0) else { return nil }
        let keyInt = sqlite3_column_int64(stmt, 4)
        // R03：metadata 读取同样守住 key/维度范围契约，坏行按不存在处理
        guard keyInt >= 0 else { return nil }
        return SemanticItem(
            id: rowID,
            contentHash: String(cString: sqlite3_column_text(stmt, 1)),
            modelVersion: String(cString: sqlite3_column_text(stmt, 2)),
            dimension: Int(sqlite3_column_int(stmt, 3)),
            vectorKey: UInt64(keyInt),
            state: String(cString: sqlite3_column_text(stmt, 5)),
            priority: Int(sqlite3_column_int(stmt, 6)),
            lastAccessedAt: dateCol(stmt, 7),
            updatedAt: dateCol(stmt, 8) ?? Date())
    }

    // MARK: - semantic_job（可恢复队列，方案 §13.4）

    func enqueueJob(_ job: SemanticJob) throws {
        try bindExec("UPDATE semantic_job SET state='cancelled' WHERE thought_id=?1 AND kind=?2 AND state IN ('pending','running') AND (content_hash != ?3 OR consent_generation != ?4)",
                     .uuid(job.thoughtID), .text(job.kind), .text(job.contentHash), .int64(job.consentGeneration))
        // actor 内先查后写，多个入口的同版本任务也只产生一个在途记录。
        if try hasPendingJob(thoughtID: job.thoughtID, contentHash: job.contentHash, kind: job.kind) { return }
        try bindExec("""
            INSERT INTO semantic_job(id, thought_id, content_hash, kind, priority, state,
                                     attempt_count, next_attempt_at, consent_generation, last_error_code)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
            ON CONFLICT(id) DO UPDATE SET priority=?5, state=?6, next_attempt_at=?8,
                consent_generation=?9, last_error_code=?10
            """,
            .uuid(job.id), .uuid(job.thoughtID), .text(job.contentHash), .text(job.kind),
            .int(Int64(job.priority)), .text(job.state), .int(Int64(job.attemptCount)),
            .date(job.nextAttemptAt), .int64(job.consentGeneration), .text(job.lastErrorCode))
    }

    /// 领取到期任务（优先级降序 → 时间升序），置 running。
    /// kind 传 nil 领取任意类型；P0-C relate 任务化后 embed/relate 执行器各领各的。
    func claimNextDueJob(now: Date = Date(), consentGeneration: Int64, kind: String? = nil) throws -> SemanticJob? {
        try exec("BEGIN IMMEDIATE")
        var claimed: SemanticJob?
        defer {
            try? exec("COMMIT")
        }
        let stmt = try prepare("""
            SELECT id, thought_id, content_hash, kind, priority, state, attempt_count,
                   next_attempt_at, consent_generation, last_error_code
            FROM semantic_job
            WHERE state='pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)
                  AND consent_generation = ?2
                  AND (?3 IS NULL OR kind=?3)
            ORDER BY priority DESC, rowid ASC LIMIT 1
            """, .date(now), .int64(consentGeneration), .text(kind))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let job = rowToJob(stmt)
        try bindExec("UPDATE semantic_job SET state='running' WHERE id=?1", .uuid(job.id))
        claimed = job
        return claimed
    }

    func finishJob(id: UUID, state: String, nextAttemptAt: Date? = nil, errorCode: String? = nil) throws {
        let terminalStates = ["done", "failed_terminal", "cancelled"]
        let finishedAt: Date? = terminalStates.contains(state) ? Date() : nil
        try bindExec("""
            UPDATE semantic_job SET state=?2, next_attempt_at=?3, last_error_code=?4,
                   attempt_count = attempt_count + 1, finished_at=COALESCE(?5, finished_at)
            WHERE id=?1 AND state != 'cancelled'
            """, .uuid(id), .text(state), .date(nextAttemptAt), .text(errorCode), .date(finishedAt))
    }

    /// 版本去重：同 (thought, hash, kind) 的 pending 任务不再重复入队（§9.1）。
    func hasPendingJob(thoughtID: UUID, contentHash: String, kind: String) throws -> Bool {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM semantic_job
            WHERE thought_id=?1 AND content_hash=?2 AND kind=?3 AND state IN('pending','running')
            """, .uuid(thoughtID), .text(contentHash), .text(kind))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    /// 撤回授权：全部 pending/running 任务终态化（不做网络调用）。
    func cancelAllJobs() throws {
        try exec("UPDATE semantic_job SET state='cancelled', last_error_code='consent_revoked' WHERE state IN('pending','running')")
    }

    /// 代数自愈（2026-10-19）：把旧代数 pending 任务 re-stamp 到当前代数。
    /// 设置开关每次变化递增 consentGeneration，旧代数任务永远不被 claimNextDueJob 领取
    /// 且无任何回收——改一次开关就冻结当时在队的全部任务。pending 尚未执行、不存在迟到
    /// 结果，re-stamp 安全；running 不碰（Executor/Verifier 落库侧的代数校验仍是防线）。
    func restampStalePendingJobs(to generation: Int64) throws {
        try bindExec("UPDATE semantic_job SET consent_generation=?1 WHERE state='pending' AND consent_generation < ?1", .int64(generation))
    }

    func pendingJobCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM semantic_job WHERE state='pending'")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 索引覆盖统计（设置页状态如实展示用，2026-09-24 方案 §5.4：
    /// pending=0 ≠ 完成——需区分待处理/失败/不适合处理/最近成功时间）。
    struct IndexStats {
        var activeItems = 0          // 已入库向量
        var runningJobs = 0
        var pendingJobs = 0          // 待处理
        var failedJobs = 0           // 失败终态（可重试）
        var unavailableDone = 0      // 合法不适处理（纯图/空文/已删）
        var lastFinishedAt: Date?    // 最近一次任务完成
        var waitingReason: String?
        var unfinishedThoughts = 0
    }

    func indexStats() throws -> IndexStats {
        var stats = IndexStats()
        let unfinished = try prepare("SELECT COUNT(DISTINCT thought_id) FROM semantic_job WHERE state IN ('pending','running')")
        if sqlite3_step(unfinished) == SQLITE_ROW { stats.unfinishedThoughts = Int(sqlite3_column_int64(unfinished, 0)) }
        sqlite3_finalize(unfinished)
        let runningStatement = try prepare("SELECT COUNT(*) FROM semantic_job WHERE state='running'")
        if sqlite3_step(runningStatement) == SQLITE_ROW { stats.runningJobs = Int(sqlite3_column_int64(runningStatement, 0)) }
        sqlite3_finalize(runningStatement)
        let waitingStatement = try prepare("SELECT last_error_code FROM semantic_job WHERE state IN ('pending','failed_terminal') AND last_error_code IS NOT NULL AND rowid IN (SELECT MAX(rowid) FROM semantic_job GROUP BY thought_id,kind) ORDER BY finished_at DESC LIMIT 1")
        if sqlite3_step(waitingStatement) == SQLITE_ROW { stats.waitingReason = textCol(waitingStatement, 0) }
        sqlite3_finalize(waitingStatement)
        if let stmt = try? prepare("SELECT COUNT(*) FROM semantic_item WHERE state='active'") {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW { stats.activeItems = Int(sqlite3_column_int64(stmt, 0)) }
        }
        if let stmt = try? prepare("""
            SELECT SUM(state='pending'), COUNT(DISTINCT CASE WHEN state='failed_terminal' THEN thought_id END),
                   SUM(state='done' AND last_error_code IN('text_unavailable','thought_unavailable')),
                   MAX(CASE WHEN state='done' AND last_error_code IS NULL THEN finished_at END)
            FROM semantic_job
            WHERE rowid IN (SELECT MAX(rowid) FROM semantic_job GROUP BY thought_id,kind)
            """) {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { stats.pendingJobs = Int(sqlite3_column_int64(stmt, 0)) }
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL { stats.failedJobs = Int(sqlite3_column_int64(stmt, 1)) }
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL { stats.unavailableDone = Int(sqlite3_column_int64(stmt, 2)) }
                stats.lastFinishedAt = dateCol(stmt, 3)
            }
        }
        return stats
    }

    /// 用户主动重试：恢复失败项，也让暂时失败的待处理项立即重试；保留取消状态。
    func retryFailedJobs() throws {
        // 只恢复最新版终态任务；旧正文/旧授权和已经有执行者的版本不能被重新点燃。
        try exec("""
            UPDATE semantic_job AS target SET state='pending', attempt_count=0,
                next_attempt_at=NULL,last_error_code=NULL
            WHERE (state='pending' AND last_error_code IS NOT NULL) OR (
                state='failed_terminal' AND rowid=(
                    SELECT MAX(rowid) FROM semantic_job WHERE thought_id=target.thought_id
                        AND kind=target.kind AND state!='cancelled')
                AND NOT EXISTS (SELECT 1 FROM semantic_job WHERE thought_id=target.thought_id
                    AND kind=target.kind AND state IN ('pending','running')))
            """)
    }

    // MARK: - 相关旧想法反馈（方案 §5.2：同版本不重复推荐）

    /// 记录「不相关」反馈：同 (thought, related) pair 后续召回排除。
    func recordRelatedFeedback(thoughtID: UUID, relatedID: UUID, basisHash: String) throws {
        try bindExec("""
            INSERT OR REPLACE INTO related_feedback(thought_id, related_id, basis_hash, created_at)
            VALUES(?1, ?2, ?3, ?4)
            """, .uuid(thoughtID), .uuid(relatedID), .text(basisHash), .date(Date()))
    }

    /// 读取想法的全部「不相关」反馈 pair（召回排除用）。
    func relatedFeedbackIDs(thoughtID: UUID) throws -> Set<UUID> {
        let stmt = try prepare("SELECT related_id FROM related_feedback WHERE thought_id=?1", .uuid(thoughtID))
        defer { sqlite3_finalize(stmt) }
        var result: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = uuidCol(stmt, 0) { result.insert(id) }
        }
        return result
    }

    // MARK: - thought_followup（W2 想法脉络核对，2026-11-16 方案 §6 C3）

    /// 设备日键（本地自然日，§5 B1「按设备日」）。
    nonisolated static func followupDeviceDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 每日新核对上限（含重试，§5 B1）：按 result 行 attempt_count 对当日 started_day 求和。
    static let followupDailyAttemptLimit = 4

    /// 幂等新建核对任务：taskKey 已存在（任何非 cancelled 状态）返回 false——
    /// 相同键 verified/no_result 皆终态不重算，重复开页与重启不重新入队（§5 B2）。
    /// cancelled 行复位复活（W3）：重新启用试点/恢复授权后同键可重算——新生命
    /// 周期 = 新 operationId、attempt 归零（日额度按新领取重新计，不绕上限）。
    @discardableResult
    func upsertFollowupTask(taskKey: String, scopeID: UUID, anchorID: UUID, policyVersion: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }
        let existing = try prepare("SELECT state FROM thought_followup_result WHERE task_key=?1", .text(taskKey))
        defer { sqlite3_finalize(existing) }
        if sqlite3_step(existing) == SQLITE_ROW {
            let state = String(cString: sqlite3_column_text(existing, 0))
            guard state == "cancelled" else { return false }
            try bindExec("""
                UPDATE thought_followup_result
                SET state='pending', next_attempt_at=NULL, run_deadline=NULL, last_error_code=NULL,
                    attempt_count=0, started_day=NULL, verified_at=NULL, operation_id=?2
                WHERE task_key=?1
                """, .text(taskKey), .text(UUID().uuidString.lowercased()))
            return true
        }
        try bindExec("""
            INSERT INTO thought_followup_result(task_key, scope_id, anchor_id, state, policy_version,
                                                operation_id, attempt_count, created_at)
            VALUES(?1,?2,?3,'pending',?4,?5,0,?6)
            """,
            .text(taskKey), .uuid(scopeID), .uuid(anchorID), .text(policyVersion),
            .text(UUID().uuidString.lowercased()), .date(Date()))
        return true
    }

    /// 领取下一个到期任务（§6 C3「领取用 SQLite 事务」+ §6 C2 末条「调用前原子标记」）：
    /// pending 或 waiting 且到期；先回收超时 running；当日额度（含重试 ≤4 次）未满才可领。
    /// 领取即置 running、attempt_count+1、首次尝试落 started_day、写入运行时限。
    func claimNextFollowupTask(now: Date = Date(),
                               runTimeout: TimeInterval = 180) throws -> FollowupResultRecord? {
        try exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }
        // 上一轮超时/中断的 running 回收为 waiting，本拍可按余量重试（复用 operationId）
        try bindExec("""
            UPDATE thought_followup_result SET state='waiting', next_attempt_at=?1
            WHERE state='running' AND (run_deadline IS NULL OR run_deadline < ?1)
            """, .date(now), .date(now))
        let day = Self.followupDeviceDay(now)
        let usage = try prepare("""
            SELECT COALESCE(SUM(attempt_count),0) FROM thought_followup_result
            WHERE started_day=?1 AND state != 'cancelled'
            """, .text(day))
        defer { sqlite3_finalize(usage) }
        guard sqlite3_step(usage) == SQLITE_ROW,
              sqlite3_column_int64(usage, 0) < Self.followupDailyAttemptLimit else { return nil }
        let claim = try prepare("""
            SELECT task_key FROM thought_followup_result
            WHERE (state='pending' OR (state='waiting' AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)))
            ORDER BY created_at ASC LIMIT 1
            """, .date(now))
        defer { sqlite3_finalize(claim) }
        guard sqlite3_step(claim) == SQLITE_ROW else { return nil }
        let taskKey = String(cString: sqlite3_column_text(claim, 0))
        try bindExec("""
            UPDATE thought_followup_result
            SET state='running', attempt_count=attempt_count+1,
                started_day=COALESCE(started_day, ?2),
                run_deadline=?3, next_attempt_at=NULL
            WHERE task_key=?1
            """, .text(taskKey), .text(day), .date(now.addingTimeInterval(runTimeout)))
        return try followupResult(taskKey: taskKey)
    }

    /// 输入映射（§6 C3「输入映射用 SQLite 事务」）：一次请求的全部输入整批落 source 行。
    func recordFollowupSources(_ records: [FollowupSourceRecord]) throws {
        guard !records.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }
        for record in records {
            let windowsJSON = (try? JSONEncoder().encode(record.windows))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try bindExec("""
                INSERT INTO thought_followup_source(task_key, thought_id, scope_id, content_hash,
                                                    redaction_version, frozen_created_at, windows_json, summary)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
                ON CONFLICT(task_key, thought_id) DO UPDATE SET content_hash=?4, redaction_version=?5,
                    frozen_created_at=?6, windows_json=?7, summary=?8
                """,
                .text(record.taskKey), .uuid(record.thoughtID), .uuid(record.scopeID),
                .text(record.contentHash), .text(record.redactionVersion),
                .date(record.frozenCreatedAt), .text(windowsJSON), .text(record.summary))
        }
    }

    /// 成功落库（§6 C3「成功落库用 SQLite 事务」）：verified 终态 + 有界判定数组 + 可选 thread。
    func finishFollowupVerified(taskKey: String,
                                decisions: [FollowupDecisionRecord],
                                thread: (id: String, title: String, question: String, memberIDs: [UUID])?,
                                now: Date = Date()) throws {
        let decisionsJSON = (try? JSONEncoder().encode(decisions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let membersJSON = (try? JSONEncoder().encode(thread.map { $0.memberIDs } ?? []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try bindExec("""
            UPDATE thought_followup_result
            SET state='verified', verified_at=?2, next_attempt_at=NULL, last_error_code=NULL,
                decisions_json=?3, thread_id=?4, thread_title=?5, thread_question=?6, thread_member_ids=?7
            WHERE task_key=?1
            """,
            .text(taskKey), .date(now), .text(decisionsJSON), .text(thread?.id),
            .text(thread?.title), .text(thread?.question), .text(membersJSON))
    }

    /// 空结果终态：没有任何可信关系时 200 全部非命中（§6 C2）；与 verified 同为终态不重算。
    func finishFollowupNoResult(taskKey: String, now: Date = Date()) throws {
        try bindExec("""
            UPDATE thought_followup_result
            SET state='no_result', verified_at=?2, next_attempt_at=NULL, last_error_code=NULL,
                decisions_json=NULL, thread_id=NULL, thread_title=NULL, thread_question=NULL, thread_member_ids=NULL
            WHERE task_key=?1
            """, .text(taskKey), .date(now))
    }

    /// 有界重试等待（§6 C3：网络/上游超时按退避，配额等下个设备日或后端重试时刻）。
    func finishFollowupWaiting(taskKey: String, nextAttemptAt: Date, errorCode: String?) throws {
        try bindExec("""
            UPDATE thought_followup_result
            SET state='waiting', next_attempt_at=?2, last_error_code=?3, run_deadline=NULL
            WHERE task_key=?1 AND state='running'
            """, .text(taskKey), .date(nextAttemptAt), .text(errorCode))
    }

    /// 终态失败：协议错/重试耗尽（§6 C2：持续协议错误只在新策略版本下解冻——
    /// policyVersion 参与 taskKey，新版本自然另起新键）。
    func finishFollowupFailed(taskKey: String, errorCode: String?) throws {
        try bindExec("""
            UPDATE thought_followup_result
            SET state='failed', next_attempt_at=NULL, last_error_code=?2, run_deadline=NULL
            WHERE task_key=?1 AND state='running'
            """, .text(taskKey), .text(errorCode))
    }

    /// 撤权、版本变更或范围退出取消旧运行（§6 C3）：scope 传 nil 取消全部。
    /// 取消是终态：不做网络调用、不占当日额度、迟到结果不得落库。
    func cancelFollowupTasks(scopeID: UUID?, errorCode: String) throws {
        if let scopeID {
            try bindExec("""
                UPDATE thought_followup_result SET state='cancelled', next_attempt_at=NULL,
                    last_error_code=?2, run_deadline=NULL
                WHERE scope_id=?1 AND state IN('pending','running','waiting')
                """, .uuid(scopeID), .text(errorCode))
        } else {
            try bindExec("""
                UPDATE thought_followup_result SET state='cancelled', next_attempt_at=NULL,
                    last_error_code=?2, run_deadline=NULL
                WHERE state IN('pending','running','waiting')
                """, .text(errorCode))
        }
    }

    /// 当日已消耗的新核对次数（含重试，§5 B1）。
    func followupDailyAttempts(now: Date = Date()) throws -> Int {
        let stmt = try prepare("""
            SELECT COALESCE(SUM(attempt_count),0) FROM thought_followup_result
            WHERE started_day=?1 AND state != 'cancelled'
            """, .text(Self.followupDeviceDay(now)))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 试点队列快照与手动重试（W3，2026-11-16 方案 §6 C3/§1 三档诊断）

    /// 按状态的队列计数（设置页三档诊断与手动重试的判定依据）。
    struct FollowupQueueStatus: Equatable {
        var pending = 0
        var running = 0
        /// waiting 且已到重试时刻（含 next_attempt_at 为空的等待行，与领取口径一致）
        var waitingDue = 0
        /// waiting 且未到期
        var waitingFuture = 0
        var failed = 0
        var verified = 0
        var noResult = 0

        /// 排队/处理中/等待中的在途键数
        var inFlight: Int { pending + running + waitingDue + waitingFuture }
        /// 完成终态（verified 含空结果终态 no_result）
        var completed: Int { verified + noResult }
    }

    /// 某试点范围的队列快照（W3 pilotStatus：在途=等待整理，failed/到期=稍后重试）。
    func followupQueueStatus(scopeID: UUID, now: Date = Date()) throws -> FollowupQueueStatus {
        let stmt = try prepare("""
            SELECT
                COALESCE(SUM(state='pending'),0),
                COALESCE(SUM(state='running'),0),
                COALESCE(SUM(state='waiting' AND (next_attempt_at IS NULL OR next_attempt_at <= ?2)),0),
                COALESCE(SUM(state='waiting' AND next_attempt_at > ?2),0),
                COALESCE(SUM(state='failed'),0),
                COALESCE(SUM(state='verified'),0),
                COALESCE(SUM(state='no_result'),0)
            FROM thought_followup_result WHERE scope_id=?1
            """, .uuid(scopeID), .date(now))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return FollowupQueueStatus() }
        return FollowupQueueStatus(
            pending: Int(sqlite3_column_int64(stmt, 0)),
            running: Int(sqlite3_column_int64(stmt, 1)),
            waitingDue: Int(sqlite3_column_int64(stmt, 2)),
            waitingFuture: Int(sqlite3_column_int64(stmt, 3)),
            failed: Int(sqlite3_column_int64(stmt, 4)),
            verified: Int(sqlite3_column_int64(stmt, 5)),
            noResult: Int(sqlite3_column_int64(stmt, 6)))
    }

    /// 手动重试（W3 诊断页「稍后重试」定向人工复测的解冻口径，§6 C2 末条）：
    /// failed 与未到期 waiting 有界复位为 pending 立即可领——attempt_count 不清零
    /// （上限口径不变），日额度仍在领取处强制 ≤4；verified/no_result/cancelled/
    /// running 不动。返回复位行数。
    @discardableResult
    func retryFollowupTasks(scopeID: UUID, now: Date = Date()) throws -> Int {
        try bindExec("""
            UPDATE thought_followup_result
            SET state='pending', next_attempt_at=NULL, run_deadline=NULL, last_error_code=NULL
            WHERE scope_id=?1 AND (state='failed' OR (state='waiting' AND next_attempt_at > ?2))
            """, .uuid(scopeID), .date(now))
        return Int(sqlite3_changes(db))
    }

    /// 试点范围切换/关闭（W3，settingsDidChange 链路）：keep 之外所有 scope 的
    /// 未终态行直接取消终态——不占日额度、不靠领取逐拍以 anchor_unavailable 排干；
    /// cancelled 行可由 upsertFollowupTask 复活（重新启用后同键重算）。keep 为
    /// nil（试点整体关闭）时取消全部在途。
    func cancelFollowupTasksOutsideScope(keep scopeID: UUID?) throws {
        if let scopeID {
            try bindExec("""
                UPDATE thought_followup_result SET state='cancelled', next_attempt_at=NULL,
                    last_error_code='scope_exited', run_deadline=NULL
                WHERE state IN('pending','running','waiting') AND scope_id != ?1
                """, .uuid(scopeID))
        } else {
            try bindExec("""
                UPDATE thought_followup_result SET state='cancelled', next_attempt_at=NULL,
                    last_error_code='scope_exited', run_deadline=NULL
                WHERE state IN('pending','running','waiting')
                """)
        }
    }

    /// 相同键终态判定（verified/no_result 皆终态，§5 B2）。
    func hasTerminalFollowup(taskKey: String) throws -> Bool {
        let stmt = try prepare("""
            SELECT COUNT(*) FROM thought_followup_result
            WHERE task_key=?1 AND state IN('verified','no_result')
            """, .text(taskKey))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    /// 单行回读（领取后快照/测试）。
    func followupResult(taskKey: String) throws -> FollowupResultRecord? {
        let stmt = try prepare("""
            SELECT task_key, scope_id, anchor_id, state, policy_version, operation_id, run_deadline,
                   next_attempt_at, attempt_count, started_day, created_at, verified_at, last_error_code,
                   decisions_json, thread_id, thread_title, thread_question, thread_member_ids
            FROM thought_followup_result WHERE task_key=?1
            """, .text(taskKey))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return followupRow(stmt)
    }

    /// 读侧展示：当前 scope 的 verified 结果（含 thread 为 nil 的相关区结果）。
    /// 30 天过期隐藏由调用侧按 verifiedAt 判断（§6 C3「过期先隐藏」）。
    func followupResults(scopeID: UUID) throws -> [FollowupResultRecord] {
        let stmt = try prepare("""
            SELECT task_key, scope_id, anchor_id, state, policy_version, operation_id, run_deadline,
                   next_attempt_at, attempt_count, started_day, created_at, verified_at, last_error_code,
                   decisions_json, thread_id, thread_title, thread_question, thread_member_ids
            FROM thought_followup_result WHERE scope_id=?1 AND state='verified'
            ORDER BY verified_at DESC
            """, .uuid(scopeID))
        defer { sqlite3_finalize(stmt) }
        var rows: [FollowupResultRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = followupRow(stmt) { rows.append(row) }
        }
        return rows
    }

    /// 一次请求的全部输入回读（结果有效性以所有输入为准，含最终没进入卡片的输入）。
    func followupSources(taskKey: String) throws -> [FollowupSourceRecord] {
        let stmt = try prepare("""
            SELECT task_key, thought_id, scope_id, content_hash, redaction_version,
                   frozen_created_at, windows_json, summary
            FROM thought_followup_source WHERE task_key=?1 ORDER BY thought_id
            """, .text(taskKey))
        defer { sqlite3_finalize(stmt) }
        var rows: [FollowupSourceRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let thoughtID = uuidCol(stmt, 1), let scopeID = uuidCol(stmt, 2) else { continue }
            let windowsData = Data(bytes: sqlite3_column_blob(stmt, 6), count: Int(sqlite3_column_bytes(stmt, 6)))
            let windows = (try? JSONDecoder().decode([FollowupWindowIndex].self, from: windowsData)) ?? []
            rows.append(FollowupSourceRecord(
                taskKey: String(cString: sqlite3_column_text(stmt, 0)),
                thoughtID: thoughtID,
                scopeID: scopeID,
                contentHash: String(cString: sqlite3_column_text(stmt, 3)),
                redactionVersion: String(cString: sqlite3_column_text(stmt, 4)),
                frozenCreatedAt: dateCol(stmt, 5) ?? Date(),
                windows: windows,
                summary: textCol(stmt, 7) ?? ""))
        }
        return rows
    }

    private func followupRow(_ stmt: OpaquePointer) -> FollowupResultRecord? {
        guard let scopeID = uuidCol(stmt, 1), let anchorID = uuidCol(stmt, 2) else { return nil }
        let decisionsData = sqlite3_column_blob(stmt, 13).map {
            Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 13)))
        }
        let decisions = decisionsData.flatMap { try? JSONDecoder().decode([FollowupDecisionRecord].self, from: $0) } ?? []
        let membersData = sqlite3_column_blob(stmt, 17).map {
            Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 17)))
        }
        let members = membersData.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
        return FollowupResultRecord(
            taskKey: String(cString: sqlite3_column_text(stmt, 0)),
            scopeID: scopeID,
            anchorID: anchorID,
            state: FollowupResultRecord.State(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .failed,
            policyVersion: String(cString: sqlite3_column_text(stmt, 4)),
            operationID: String(cString: sqlite3_column_text(stmt, 5)),
            runDeadline: dateCol(stmt, 6),
            nextAttemptAt: dateCol(stmt, 7),
            attemptCount: Int(sqlite3_column_int64(stmt, 8)),
            startedDay: textCol(stmt, 9),
            createdAt: dateCol(stmt, 10) ?? Date(),
            verifiedAt: dateCol(stmt, 11),
            lastErrorCode: textCol(stmt, 12),
            decisions: decisions,
            threadID: textCol(stmt, 14),
            threadTitle: textCol(stmt, 15),
            threadQuestion: textCol(stmt, 16),
            threadMemberIDs: members)
    }

    /// 保留淘汰（§6 C3）：结果主体 ≤30 天或每主题 200 批次（取先触发，运行中的不强行淘汰）；
    /// 过期先隐藏（读侧按 verifiedAt 判断）再清可重建内容（判定/thread 正文与 source 窗口），
    /// 完成凭证行（taskKey+状态+时间）保留防重调；每锚点只留最新完成凭证、全 scope ≤120。
    /// 只因过期、容量清理或重复开页不会重试同一个键——凭证行本身即防重入。
    func pruneFollowupRetention(scopeID: UUID,
                                now: Date = Date(),
                                maxAgeDays: Double = 30,
                                maxBatchesPerScope: Int = 200,
                                maxAnchorReceipts: Int = 120) throws {
        // 1) 超龄与超批次的完成行：清可重建内容 + 对应 source 窗口（凭证行保留）
        let cutoff = now.addingTimeInterval(-maxAgeDays * 86_400)
        try bindExec("""
            UPDATE thought_followup_result
            SET decisions_json=NULL, thread_id=NULL, thread_title=NULL, thread_question=NULL, thread_member_ids=NULL
            WHERE scope_id=?1 AND state IN('verified','no_result')
                  AND verified_at < ?2
                  AND (decisions_json IS NOT NULL OR thread_title IS NOT NULL)
            """, .uuid(scopeID), .date(cutoff))
        let staleKeys = try prepare("""
            SELECT task_key FROM thought_followup_result
            WHERE scope_id=?1 AND state IN('verified','no_result')
                  AND (decisions_json IS NOT NULL OR thread_title IS NOT NULL)
            ORDER BY verified_at ASC LIMIT -1 OFFSET ?2
            """, .uuid(scopeID), .int64(Int64(maxBatchesPerScope)))
        var overflowKeys: [String] = []
        while sqlite3_step(staleKeys) == SQLITE_ROW {
            overflowKeys.append(String(cString: sqlite3_column_text(staleKeys, 0)))
        }
        sqlite3_finalize(staleKeys)
        for key in overflowKeys {
            try bindExec("""
                UPDATE thought_followup_result
                SET decisions_json=NULL, thread_id=NULL, thread_title=NULL, thread_question=NULL, thread_member_ids=NULL
                WHERE task_key=?1
                """, .text(key))
        }
        // 2) 每锚点只保留最新完成凭证：同锚点旧终态行删除
        let anchors = try prepare("""
            SELECT anchor_id, MAX(verified_at) FROM thought_followup_result
            WHERE scope_id=?1 AND state IN('verified','no_result') GROUP BY anchor_id
            """, .uuid(scopeID))
        var anchorLatest: [(UUID, Date)] = []
        while sqlite3_step(anchors) == SQLITE_ROW {
            if let id = uuidCol(anchors, 0), let latest = dateCol(anchors, 1) {
                anchorLatest.append((id, latest))
            }
        }
        sqlite3_finalize(anchors)
        for (anchorID, latest) in anchorLatest {
            try bindExec("""
                DELETE FROM thought_followup_result
                WHERE scope_id=?1 AND anchor_id=?2 AND state IN('verified','no_result') AND verified_at < ?3
                """, .uuid(scopeID), .uuid(anchorID), .date(latest))
        }
        // 3) 全 scope 完成凭证 ≤120：按锚点最旧完成时间淘汰整组凭证行
        if anchorLatest.count > maxAnchorReceipts {
            let evict = anchorLatest.sorted { $0.1 < $1.1 }.prefix(anchorLatest.count - maxAnchorReceipts)
            for (anchorID, _) in evict {
                try bindExec("""
                    DELETE FROM thought_followup_result
                    WHERE scope_id=?1 AND anchor_id=?2 AND state IN('verified','no_result')
                    """, .uuid(scopeID), .uuid(anchorID))
            }
        }
        // 4) source 窗口随可重建内容清理：终态且内容已空的行、以及 result 行已被
        //    整行删除（每锚点最新/凭证上限）后的孤儿 source 一并清掉
        try bindExec("""
            DELETE FROM thought_followup_source
            WHERE scope_id=?1 AND (
                task_key NOT IN (SELECT task_key FROM thought_followup_result WHERE scope_id=?1)
                OR task_key IN (SELECT task_key FROM thought_followup_result
                                WHERE scope_id=?1 AND state IN('verified','no_result')
                                  AND decisions_json IS NULL AND thread_title IS NULL))
            """, .uuid(scopeID))
    }

    /// 隐藏一条脉络卡（本机独立操作，§6 C1/§5 B2）：scope × thread local ID +
    /// 确认展示过的成员 ID 集（高重叠压制用）；幂等覆盖。
    func recordFollowupDismissal(scopeID: UUID, threadID: String, memberIDs: [UUID]) throws {
        let membersJSON = (try? JSONEncoder().encode(memberIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try bindExec("""
            INSERT INTO thought_followup_dismissal(scope_id, thread_id, member_ids, created_at)
            VALUES(?1,?2,?3,?4)
            ON CONFLICT(scope_id, thread_id) DO UPDATE SET member_ids=?3, created_at=?4
            """, .uuid(scopeID), .text(threadID), .text(membersJSON), .date(Date()))
    }

    func followupDismissals(scopeID: UUID) throws -> [FollowupDismissalRecord] {
        let stmt = try prepare("""
            SELECT scope_id, thread_id, member_ids, created_at
            FROM thought_followup_dismissal WHERE scope_id=?1
            """, .uuid(scopeID))
        defer { sqlite3_finalize(stmt) }
        var rows: [FollowupDismissalRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let scope = uuidCol(stmt, 0) else { continue }
            let membersData = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
            let members = (try? JSONDecoder().decode([UUID].self, from: membersData)) ?? []
            rows.append(FollowupDismissalRecord(
                scopeID: scope,
                threadID: String(cString: sqlite3_column_text(stmt, 1)),
                memberIDs: members,
                createdAt: dateCol(stmt, 3) ?? Date()))
        }
        return rows
    }

    /// 撤权/范围退出的有界清理入口（§6 C3）：清该 scope 的结果与来源行。
    /// 隐藏回执保留（Dismissal 行「日常重算与回滚保留拒绝」，仅含稳定 ID 无内容，
    /// 相关 pair 拒绝走既有 related_feedback）；「清除设备索引」走 destroyAllData
    /// 整库销毁，本机反馈一并清掉。
    func destroyFollowupData(scopeID: UUID) throws {
        try exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }
        try bindExec("DELETE FROM thought_followup_result WHERE scope_id=?1", .uuid(scopeID))
        try bindExec("DELETE FROM thought_followup_source WHERE scope_id=?1", .uuid(scopeID))
    }

    // MARK: - manifest

    func manifest() throws -> Manifest {
        let stmt = try prepare("""
            SELECT schema_version, active_model_version, building_model_version,
                   index_generation, next_vector_key, last_compacted_at FROM semantic_manifest WHERE id=1
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            // 首次：写默认 manifest
            let m = Manifest(schemaVersion: Self.schemaVersion,
                             activeModelVersion: Self.defaultModelVersion,
                             buildingModelVersion: nil,
                             indexGeneration: 0,
                             nextVectorKey: 1,
                             lastCompactedAt: nil)
            try saveManifest(m)
            return m
        }
        return Manifest(
            schemaVersion: Int(sqlite3_column_int64(stmt, 0)),
            activeModelVersion: String(cString: sqlite3_column_text(stmt, 1)),
            buildingModelVersion: textCol(stmt, 2),
            indexGeneration: Int(sqlite3_column_int64(stmt, 3)),
            nextVectorKey: UInt64(sqlite3_column_int64(stmt, 4)),
            lastCompactedAt: dateCol(stmt, 5))
    }

    func saveManifest(_ m: Manifest) throws {
        guard m.schemaVersion == Self.schemaVersion else {
            throw StoreError.schemaVersionUnsupported(m.schemaVersion)
        }
        try bindExec("""
            INSERT INTO semantic_manifest(id, schema_version, active_model_version, building_model_version,
                                          index_generation, next_vector_key, last_compacted_at)
            VALUES(1,?1,?2,?3,?4,?5,?6)
            ON CONFLICT(id) DO UPDATE SET schema_version=?1, active_model_version=?2,
                building_model_version=?3, index_generation=?4, next_vector_key=?5, last_compacted_at=?6
            """,
            .int(Int64(m.schemaVersion)), .text(m.activeModelVersion), .text(m.buildingModelVersion),
            .int(Int64(m.indexGeneration)), .int64(Int64(m.nextVectorKey)), .date(m.lastCompactedAt))
    }

    /// 分配 vector_key（单调递增，供索引 key 映射）。
    func allocateVectorKey() throws -> UInt64 {
        var m = try manifest()
        let key = m.nextVectorKey
        m.nextVectorKey += 1
        try saveManifest(m)
        return key
    }

    // MARK: - schema（六表一次到位；后三表 API 在 Phase 3/5 落地）

    private func migrateIfNeeded() throws {
        try exec("CREATE TABLE IF NOT EXISTS topic_profile(topic_id BLOB PRIMARY KEY,content_hash TEXT NOT NULL,model_version TEXT NOT NULL,dimension INTEGER NOT NULL,vector_f16 BLOB NOT NULL)")
        try exec("""
            CREATE TABLE IF NOT EXISTS semantic_manifest(
                id INTEGER PRIMARY KEY CHECK(id=1),
                schema_version INTEGER NOT NULL,
                active_model_version TEXT NOT NULL,
                building_model_version TEXT,
                index_generation INTEGER NOT NULL DEFAULT 0,
                next_vector_key INTEGER NOT NULL DEFAULT 1,
                last_compacted_at REAL)
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS semantic_item(
                id BLOB PRIMARY KEY,
                thought_id BLOB NOT NULL UNIQUE,
                content_hash TEXT NOT NULL,
                model_version TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector_key INTEGER NOT NULL UNIQUE,
                state TEXT NOT NULL DEFAULT 'active',
                priority INTEGER NOT NULL DEFAULT 0,
                last_accessed_at REAL,
                updated_at REAL NOT NULL,
                vector_f16 BLOB NOT NULL)
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_semantic_item_model ON semantic_item(model_version, state)")
        try exec("""
            CREATE TABLE IF NOT EXISTS semantic_job(
                id BLOB PRIMARY KEY,
                thought_id BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                kind TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL DEFAULT 'pending',
                attempt_count INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL,
                consent_generation INTEGER NOT NULL DEFAULT 0,
                last_error_code TEXT)
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_semantic_job_state ON semantic_job(state, next_attempt_at)")
        try exec("""
            CREATE TABLE IF NOT EXISTS topic_centroid(
                topic_id BLOB NOT NULL,
                model_version TEXT NOT NULL,
                vector_key INTEGER NOT NULL,
                member_revision INTEGER NOT NULL DEFAULT 0,
                weight_sum REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(topic_id, model_version))
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS relation_candidate(
                thought_id BLOB NOT NULL,
                topic_id BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                score_features TEXT,
                verifier_result TEXT,
                state TEXT NOT NULL DEFAULT 'candidate',
                engine_version TEXT,
                expires_at REAL,
                PRIMARY KEY(thought_id, topic_id))
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS candidate_cluster(
                id TEXT PRIMARY KEY,
                fingerprint TEXT NOT NULL UNIQUE,
                centroid_key INTEGER,
                member_ids TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'growing',
                cohesion REAL NOT NULL DEFAULT 0,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                dismissed_until REAL)
            """)
        // Phase 5：主题摘要（AI 派生，不进 CloudKit；随销毁入口整体清除）
        try exec("""
            CREATE TABLE IF NOT EXISTS topic_summary(
                topic_id BLOB PRIMARY KEY,
                model_version TEXT NOT NULL,
                basis_revision INTEGER NOT NULL DEFAULT 0,
                summary TEXT NOT NULL,
                viewpoints_json TEXT NOT NULL DEFAULT '[]',
                updated_at REAL NOT NULL)
            """)
        // 类别理解 brief（2026-10-12 主题双通道·零打扰）：AI 起草/精化的「收什么」定义
        // 与排除边界，AI 派生只存本机不进 CloudKit；exclusions_json 是字符串数组。
        // basis_* 记录生成时的证据规模：member_count/removal_count 变化到阈值才触发精化，
        // 排除项在客户端只增不减（边界只由用户移出动作改写的机器强制依据）。
        try exec("""
            CREATE TABLE IF NOT EXISTS category_brief(
                topic_id BLOB PRIMARY KEY,
                version INTEGER NOT NULL DEFAULT 1,
                definition TEXT NOT NULL,
                exclusions_json TEXT NOT NULL DEFAULT '[]',
                basis_member_count INTEGER NOT NULL DEFAULT 0,
                basis_removal_count INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL)
            """)
        // Phase 5：建议卡命名（轻量加列；重复加列错误幂等吞掉）
        try? exec("ALTER TABLE candidate_cluster ADD COLUMN name TEXT")
        // 索引覆盖统计：任务完成时间（重复加列幂等吞掉，2026-09-24 方案 §5.4）
        try? exec("ALTER TABLE semantic_job ADD COLUMN finished_at REAL")
        // P0-B（2026-09-27）：证据原文片段随决策记录落库，供 P1「为什么归在这里」回源展示
        try? exec("ALTER TABLE relation_candidate ADD COLUMN verifier_quote TEXT")
        // W1 类别规则层诊断（2026-11-16 方案 §4 A2）：schema 4 影子评测的可观测产物，
        // 只存稳定 ID、正文哈希与原因码，不进 CloudKit。
        try exec("""
            CREATE TABLE IF NOT EXISTS category_rules_diagnostic(
                thought_id BLOB NOT NULL,
                topic_id BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                reason TEXT NOT NULL,
                mode TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY(thought_id, topic_id, reason))
            """)
        // 相关旧想法反馈墓碑（方案 §5.2：同正文版本「不相关」后不重复推荐）
        try exec("""
            CREATE TABLE IF NOT EXISTS related_feedback(
                thought_id BLOB NOT NULL,
                related_id BLOB NOT NULL,
                basis_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY(thought_id, related_id))
            """)
        // 脉络核对三表（W2，2026-11-16 方案 §6 C3）：result 主键 taskKey；
        // source 记录请求全部输入（taskKey × thoughtID）；dismissal 本机隐藏回执。
        // AI 派生只留本机语义库，不进 Core Data / CloudKit；随销毁入口整体清除。
        try exec("""
            CREATE TABLE IF NOT EXISTS thought_followup_result(
                task_key TEXT PRIMARY KEY,
                scope_id BLOB NOT NULL,
                anchor_id BLOB NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                policy_version TEXT NOT NULL,
                operation_id TEXT NOT NULL,
                run_deadline REAL,
                next_attempt_at REAL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                started_day TEXT,
                created_at REAL NOT NULL,
                verified_at REAL,
                last_error_code TEXT,
                decisions_json TEXT,
                thread_id TEXT,
                thread_title TEXT,
                thread_question TEXT,
                thread_member_ids TEXT)
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_followup_result_scope ON thought_followup_result(scope_id, state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_followup_result_anchor ON thought_followup_result(scope_id, anchor_id)")
        try exec("""
            CREATE TABLE IF NOT EXISTS thought_followup_source(
                task_key TEXT NOT NULL,
                thought_id BLOB NOT NULL,
                scope_id BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                redaction_version TEXT NOT NULL,
                frozen_created_at REAL NOT NULL,
                windows_json TEXT NOT NULL,
                summary TEXT NOT NULL,
                PRIMARY KEY(task_key, thought_id))
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_followup_source_thought ON thought_followup_source(thought_id)")
        try exec("""
            CREATE TABLE IF NOT EXISTS thought_followup_dismissal(
                scope_id BLOB NOT NULL,
                thread_id TEXT NOT NULL,
                member_ids TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY(scope_id, thread_id))
            """)
        let m = try manifest()
        guard m.schemaVersion <= Self.schemaVersion else {
            throw StoreError.schemaVersionUnsupported(m.schemaVersion)
        }
    }

    // MARK: - SQLite 薄封装

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(code: sqlite3_errcode(db), sql: String(sql.prefix(120)))
        }
    }

    private enum Bind {
        case uuid(UUID)
        case text(String?)
        case int(Int64)
        case int64(Int64)
        case double(Double)
        case date(Date?)
        case blob(Data)
    }

    private func prepare(_ sql: String, _ binds: Bind...) throws -> OpaquePointer {
        try prepare(sql, binds: binds)
    }

    private func prepare(_ sql: String, binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlFailed(code: sqlite3_errcode(db), sql: String(sql.prefix(120)))
        }
        for (i, b) in binds.enumerated() { bindValue(b, to: stmt, at: Int32(i + 1)) }
        return stmt
    }

    private func bindExec(_ sql: String, _ binds: Bind...) throws {
        let stmt = try prepare(sql, binds: binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlFailed(code: sqlite3_errcode(db), sql: String(sql.prefix(120)))
        }
    }

    private func bindValue(_ b: Bind, to stmt: OpaquePointer, at idx: Int32) {
        switch b {
        case .uuid(let u):
            _ = withUnsafeBytes(of: u.uuid) { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
        case .text(let s):
            if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR) } else { sqlite3_bind_null(stmt, idx) }
        case .int(let v), .int64(let v):
            sqlite3_bind_int64(stmt, idx, v)
        case .double(let d):
            sqlite3_bind_double(stmt, idx, d)
        case .date(let d):
            if let d { sqlite3_bind_double(stmt, idx, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, idx) }
        case .blob(let data):
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
        }
    }

    /// UUID 以 16 字节 BLOB 存储；从列读回 UUID。
    private func uuidCol(_ stmt: OpaquePointer, _ idx: Int32) -> UUID? {
        guard sqlite3_column_type(stmt, idx) == SQLITE_BLOB,
              let blob = sqlite3_column_blob(stmt, idx) else { return nil }
        let b = blob.assumingMemoryBound(to: UInt8.self)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func textCol(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, idx))
    }

    private func dateCol(_ stmt: OpaquePointer, _ idx: Int32) -> Date? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
    }

    private func rowToJob(_ stmt: OpaquePointer) -> SemanticJob {
        SemanticJob(
            id: uuidCol(stmt, 0) ?? UUID(),
            thoughtID: uuidCol(stmt, 1) ?? UUID(),
            contentHash: String(cString: sqlite3_column_text(stmt, 2)),
            kind: String(cString: sqlite3_column_text(stmt, 3)),
            priority: Int(sqlite3_column_int(stmt, 4)),
            state: String(cString: sqlite3_column_text(stmt, 5)),
            attemptCount: Int(sqlite3_column_int(stmt, 6)),
            nextAttemptAt: dateCol(stmt, 7),
            consentGeneration: sqlite3_column_int64(stmt, 8),
            lastErrorCode: textCol(stmt, 9))
    }

    private func f16Blob(_ vector: [Float16]) -> Data {
        Data(bytes: vector, count: vector.count * MemoryLayout<Float16>.size)
    }
}
