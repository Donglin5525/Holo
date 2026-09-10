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
import SQLite3

/// SQLITE_TRANSIENT 是 C 宏，Swift 侧需手工等价定义
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ThoughtSemanticStore {

    enum StoreError: Error, Equatable {
        case openFailed(code: Int32)
        case sqlFailed(code: Int32, sql: String)
        case schemaVersionUnsupported(Int)
        case jobNotFound(UUID)
    }

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
        guard sqlite3_open_v2(dbPath.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.openFailed(code: sqlite3_errcode(handle))
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrateIfNeeded()
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

    // MARK: - semantic_item

    /// 写入/更新向量真身（Float16 blob）。
    func upsertItem(_ item: SemanticItem, vector: [Float16]) throws {
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
            let key = UInt64(sqlite3_column_int64(stmt, 1))
            let dim = Int(sqlite3_column_int(stmt, 2))
            var vector = [Float](repeating: 0, count: dim)
            if let blob = sqlite3_column_blob(stmt, 3) {
                let ptr = blob.assumingMemoryBound(to: Float16.self)
                for i in 0..<dim { vector[i] = Float(ptr[i]) }
            }
            rows.append((id, key, vector))
        }
        return rows
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

    /// 读取单条想法的当前向量（Float32；无/墓碑返回 nil）。
    func loadVector(thoughtID: UUID) throws -> [Float]? {
        let stmt = try prepare(
            """
            SELECT dimension, vector_f16 FROM semantic_item
            WHERE thought_id=?1 AND state='active'
            """,
            .uuid(thoughtID))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let dim = Int(sqlite3_column_int(stmt, 0))
        var vector = [Float](repeating: 0, count: dim)
        if let blob = sqlite3_column_blob(stmt, 1) {
            let ptr = blob.assumingMemoryBound(to: Float16.self)
            for i in 0..<dim { vector[i] = Float(ptr[i]) }
        }
        return vector
    }

    /// 记录一次影子关联决策（relation_candidate 表，Phase 3 shadow 主产物）。
    func recordRelationCandidate(thoughtID: UUID,
                                 topicID: UUID,
                                 contentHash: String,
                                 scoreFeatures: String,
                                 verifierResult: String,
                                 state: String,
                                 engineVersion: String,
                                 expiryDays: Int) throws {
        let expires = Date().addingTimeInterval(Double(expiryDays) * 86_400)
        try bindExec("""
            INSERT INTO relation_candidate(thought_id, topic_id, content_hash, score_features,
                                           verifier_result, state, engine_version, expires_at)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
            ON CONFLICT(thought_id, topic_id) DO UPDATE SET content_hash=?3, score_features=?4,
                verifier_result=?5, state=?6, engine_version=?7, expires_at=?8
            """,
            .uuid(thoughtID), .uuid(topicID), .text(contentHash), .text(scoreFeatures),
            .text(verifierResult), .text(state), .text(engineVersion), .date(expires))
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
        return SemanticItem(
            id: rowID,
            contentHash: String(cString: sqlite3_column_text(stmt, 1)),
            modelVersion: String(cString: sqlite3_column_text(stmt, 2)),
            dimension: Int(sqlite3_column_int(stmt, 3)),
            vectorKey: UInt64(sqlite3_column_int64(stmt, 4)),
            state: String(cString: sqlite3_column_text(stmt, 5)),
            priority: Int(sqlite3_column_int(stmt, 6)),
            lastAccessedAt: dateCol(stmt, 7),
            updatedAt: dateCol(stmt, 8) ?? Date())
    }

    // MARK: - semantic_job（可恢复队列，方案 §13.4）

    @discardableResult
    func enqueueJob(_ job: SemanticJob) throws {
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
    func claimNextDueJob(now: Date = Date(), consentGeneration: Int64) throws -> SemanticJob? {
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
                  AND consent_generation <= ?2
            ORDER BY priority DESC, rowid ASC LIMIT 1
            """, .date(now), .int64(consentGeneration))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let job = rowToJob(stmt)
        try bindExec("UPDATE semantic_job SET state='running' WHERE id=?1", .uuid(job.id))
        claimed = job
        return claimed
    }

    func finishJob(id: UUID, state: String, nextAttemptAt: Date? = nil, errorCode: String? = nil) throws {
        try bindExec("""
            UPDATE semantic_job SET state=?2, next_attempt_at=?3, last_error_code=?4,
                   attempt_count = attempt_count + 1
            WHERE id=?1
            """, .uuid(id), .text(state), .date(nextAttemptAt), .text(errorCode))
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

    func pendingJobCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM semantic_job WHERE state='pending'")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
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
        // Phase 5：建议卡命名（轻量加列；重复加列错误幂等吞掉）
        try? exec("ALTER TABLE candidate_cluster ADD COLUMN name TEXT")
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
            withUnsafeBytes(of: u.uuid) { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
        case .text(let s):
            if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR) } else { sqlite3_bind_null(stmt, idx) }
        case .int(let v), .int64(let v):
            sqlite3_bind_int64(stmt, idx, v)
        case .double(let d):
            sqlite3_bind_double(stmt, idx, d)
        case .date(let d):
            if let d { sqlite3_bind_double(stmt, idx, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, idx) }
        case .blob(let data):
            data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR) }
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
