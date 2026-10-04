import Accelerate
import Foundation
import SQLite3

// V3 Phase 2 standalone：本机语义库（SQLite）+ Flat 索引 + 向量数学的行为锁定。
// USearch 索引实现的行为由 spike（15/15）与主工程编译+模拟器冒烟覆盖。
// 运行：bash scripts/run-thought-semantic-store-standalone.sh

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ThoughtSemanticStoreStandaloneTests.main()
    }
}
#endif
struct ThoughtSemanticStoreStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-v3-test-\(UUID().uuidString)")
        try await storeLifecycleAndCRUD(tmp)
        try await jobQueueSemantics(tmp)
        await flatIndexBehavior()
        vectorMath()
        try await destroySemantics(tmp)
        try await malformedVectorAndOpenContract(tmp)
        try? FileManager.default.removeItem(at: tmp)
        print("PASS: store生命周期+Float16往返+版本判定+job去重/领取/取消+flat检索正确性+销毁重建+向量数学+R03/R14异常契约")
    }

    // MARK: - 1. store 生命周期与 CRUD

    static func storeLifecycleAndCRUD(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()

        let m = try await store.manifest()
        check(m.schemaVersion == ThoughtSemanticStore.schemaVersion && m.nextVectorKey == 1, "默认 manifest")

        // 1024 维归一化向量写入读回（Float16 往返）
        var vector = (0..<1024).map { _ in Float.random(in: -1...1) }
        vector = SemanticVectorMath.normalized(vector)
        let id = UUID()
        let key = try await store.allocateVectorKey()
        let item = ThoughtSemanticStore.SemanticItem(
            id: id, contentHash: "abc123", modelVersion: ThoughtSemanticStore.defaultModelVersion,
            dimension: 1024, vectorKey: key, state: "active", priority: 0,
            lastAccessedAt: nil, updatedAt: Date())
        try await store.upsertItem(item, vector: vector.map(Float16.init))

        let loaded = try await store.loadAllActiveVectors(modelVersion: ThoughtSemanticStore.defaultModelVersion)
        check(loaded.count == 1 && loaded[0].id == id && loaded[0].key == key, "向量行往返")
        var maxErr: Float = 0
        for (a, b) in zip(vector, loaded[0].vector) { maxErr = max(maxErr, abs(a - b)) }
        check(maxErr < 0.005, "Float16 往返误差应 <5e-3，实测 \(maxErr)")

        // 版本判定：同 hash 同模型 → 已完成；不同 hash → 需重算
        check(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123",
                                            modelVersion: ThoughtSemanticStore.defaultModelVersion))
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "changed",
                                              modelVersion: ThoughtSemanticStore.defaultModelVersion)))
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123", modelVersion: "other-v9")))

        // tombstone 后不再算已完成
        try await store.tombstoneItem(thoughtID: id)
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123",
                                              modelVersion: ThoughtSemanticStore.defaultModelVersion)), "墓碑后视为未完成")

        // 崩溃恢复语义：新实例同路径重开，数据仍在（SQLite 真身）
        await store.close()
        let reopened = await ThoughtSemanticStore(root: root)
        try await reopened.open()
        let m2 = try await reopened.manifest()
        check(m2.nextVectorKey == key + 1, "重开后 manifest 延续（vectorKey 不回卷）")
    }

    // MARK: - 2. job 队列语义

    static func jobQueueSemantics(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let t = UUID()

        func job(_ hash: String, priority: Int = 0, consent: Int64 = 0) -> ThoughtSemanticStore.SemanticJob {
            ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: t, contentHash: hash, kind: "embed",
                                             priority: priority, state: "pending", attemptCount: 0,
                                             nextAttemptAt: nil, consentGeneration: consent, lastErrorCode: nil)
        }
        try await store.enqueueJob(job("h1"))
        try await store.enqueueJob(job("h1")) // 同 (thought,hash,kind) 重复入队不产生新行
        check(try await store.hasPendingJob(thoughtID: t, contentHash: "h1", kind: "embed"), "pending 判定")
        check(!(try await store.hasPendingJob(thoughtID: t, contentHash: "h2", kind: "embed")), "不同 hash 不算")

        try await store.enqueueJob(job("h2", priority: 10))
        let claimed = try await store.claimNextDueJob(consentGeneration: 0)
        check(claimed?.contentHash == "h2", "高优先级先领取")
        try await store.finishJob(id: claimed!.id, state: "done")

        // 未来到期时间不领取
        let future = job("h3")
        try await store.enqueueJob(ThoughtSemanticStore.SemanticJob(
            id: future.id, thoughtID: t, contentHash: "h3", kind: "embed", priority: 0, state: "pending",
            attemptCount: 0, nextAttemptAt: Date().addingTimeInterval(3600),
            consentGeneration: 0, lastErrorCode: nil))
        check(try await store.claimNextDueJob(consentGeneration: 0)?.contentHash == "h1", "未到期不领取")

        // 撤权：高于当前 generation 的任务不领取；cancelAll 终态化
        try await store.enqueueJob(job("h4", consent: 5))
        check(try await store.claimNextDueJob(consentGeneration: 1)?.contentHash != "h4", "高 generation 任务不被旧授权领取")
        try await store.cancelAllJobs()
        check(try await store.pendingJobCount() == 0, "cancelAll 后无 pending")
    }

    // MARK: - 3. Flat 索引检索正确性

    static func flatIndexBehavior() async {
        let index = FlatSemanticIndex()
        var rng = SystemRandomNumberGenerator()
        func unitVector(_ dim: Int) -> [Float] {
            var v = (0..<dim).map { _ in Float(Float64.random(in: -1...1, using: &rng)) }
            return SemanticVectorMath.normalized(v)
        }

        // 100 条 256 维，分 5 个簇
        let centroids = (0..<5).map { _ in unitVector(256) }
        var ids: [UUID] = []
        for i in 0..<100 {
            let id = UUID()
            ids.append(id)
            var v = zip(centroids[i % 5], unitVector(256)).map { $0 * 0.8 + $1 * 0.2 }
            v = SemanticVectorMath.normalized(v)
            try? await index.upsert(id: id, vector: v,
                                    metadata: SemanticIndexMetadata(thoughtID: id, contentHash: "h\(i)",
                                                                    modelVersion: "t", dimension: 256))
        }

        // 用第一个簇心查询：top-5 应全部属于同簇
        let results = (try? await index.search(vector: centroids[0], topK: 5, filter: nil)) ?? []
        check(results.count == 5, "top-5 返回 5 条")
        let topIDs = Set(results.map(\.thoughtID))
        check(topIDs.count == 5 && topIDs.isSubset(of: ids), "命中的都是已插向量")

        // filter 排除 top1 后不再出现
        let excluded = results[0].thoughtID
        let filtered = (try? await index.search(vector: centroids[0], topK: 5,
                                                 filter: SemanticIndexFilter(excludedIDs: [excluded]))) ?? []
        check(!filtered.contains { $0.thoughtID == excluded }, "被排除 id 不出现")

        // remove 后不再命中
        try? await index.remove(id: excluded)
        let afterRemove = (try? await index.search(vector: centroids[0], topK: 100, filter: nil)) ?? []
        check(!afterRemove.contains { $0.thoughtID == excluded }, "已删 id 不命中")
        check(afterRemove.count == 99)

        // 未归一化向量必须拒绝（管线纪律）
        var threw = false
        do { try await index.upsert(id: UUID(), vector: (0..<256).map { _ in Float(1) },
                                    metadata: SemanticIndexMetadata(thoughtID: UUID(), contentHash: "x",
                                                                    modelVersion: "t", dimension: 256)) }
        catch { threw = true }
        check(threw, "未归一化向量应抛错")

        try? await index.destroy()
        let health = (try? await index.validate())!
        check(health.entryCount == 0, "销毁后清空")
    }

    // MARK: - 4. 销毁重建（「删除设备智能索引」入口）

    static func destroySemantics(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let item = ThoughtSemanticStore.SemanticItem(
            id: UUID(), contentHash: "z", modelVersion: "m", dimension: 8, vectorKey: 999,
            state: "active", priority: 0, lastAccessedAt: nil, updatedAt: Date())
        try await store.upsertItem(item, vector: .init(repeating: Float16(0.25), count: 8))
        try await store.destroyAllData()
        let after = try await store.loadAllActiveVectors(modelVersion: "m")
        check(after.isEmpty, "销毁后库为空且句柄可用（重建目录+重开）")
    }

    // MARK: - 5. 向量数学

    static func vectorMath() {
        let v = SemanticVectorMath.normalized([3, 4])
        check(abs(SemanticVectorMath.cosineSimilarity(v, v) - 1) < 0.001, "自相似≈1")
        check(SemanticVectorMath.normalized([0, 0]) == [0, 0], "零向量原样返回")
    }

    // MARK: - 6. R03/R14 异常输入契约（2026-10-04 体检回归）

    static func malformedVectorAndOpenContract(_ root: URL) async throws {
        // —— R03 写入契约：维度为正数且等于向量元素数，先校验后落库 ——
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let key = try await store.allocateVectorKey()
        let id = UUID()
        func draft(dim: Int) -> ThoughtSemanticStore.SemanticItem {
            ThoughtSemanticStore.SemanticItem(id: id, contentHash: "contract", modelVersion: "m",
                                              dimension: dim, vectorKey: key, state: "active",
                                              priority: 0, lastAccessedAt: nil, updatedAt: Date())
        }
        var threw = false
        do { try await store.upsertItem(draft(dim: 4), vector: .init(repeating: Float16(1), count: 3)) }
        catch { threw = true }
        check(threw, "维度与向量元素数不一致必须抛错")
        threw = false
        do { try await store.upsertItem(draft(dim: 0), vector: []) }
        catch { threw = true }
        check(threw, "非正维度必须抛错")
        check(try await store.loadAllActiveVectors(modelVersion: "m").isEmpty, "被拒数据不得落库")
        // 合法写入对照：契约只拦坏数据，不伤正常路径
        try await store.upsertItem(draft(dim: 4), vector: .init(repeating: Float16(0.5), count: 4))
        await store.close()

        // —— R03 读取契约：历史坏行（负维度 / 短 BLOB）隔离跳过，不崩溃 ——
        let dbPath = root.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite")
        let negativeDimID = UUID()
        let shortBlobID = UUID()
        try injectRawVectorRow(into: dbPath, id: negativeDimID, modelVersion: "m",
                               dimension: -1, vectorKey: 9001, blob: Data([0x00, 0x00]))
        try injectRawVectorRow(into: dbPath, id: shortBlobID, modelVersion: "m",
                               dimension: 1024, vectorKey: 9002, blob: Data([0x00, 0x00]))
        let reopened = await ThoughtSemanticStore(root: root)
        try await reopened.open()
        let rows = try await reopened.loadAllActiveVectors(modelVersion: "m")
        check(rows.count == 1 && rows[0].vector.count == 4, "坏行被隔离，仅合法行返回，实测 \(rows.count) 行")
        check(try await reopened.activeVector(thoughtID: negativeDimID, contentHash: "dirty", modelVersion: "m") == nil,
              "负维度行读取安全拒绝")
        check(try await reopened.loadVector(thoughtID: shortBlobID) == nil, "短 BLOB 行读取安全拒绝")
        check(try await reopened.item(thoughtID: negativeDimID)?.vectorKey == 9001, "元数据行正常读回（key 范围内）")

        // —— R14 打开失败：错误码必须是真实打开结果，不得是关闭后查询所得 MISUSE(21) ——
        let occupied = root.appendingPathComponent("occupied-root")
        try Data("not a directory".utf8).write(to: occupied)
        var probe: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let realRC = sqlite3_open_v2(occupied.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite").path,
                                     &probe, flags, nil)
        if let probe { sqlite3_close_v2(probe) }
        check(realRC != SQLITE_OK && realRC != SQLITE_MISUSE, "探针路径应真实打开失败，rc=\(realRC)")
        let blocked = await ThoughtSemanticStore(root: occupied)
        do {
            try await blocked.open()
            check(false, "目录被文件占据时必须打开失败")
        } catch let error as ThoughtSemanticStore.StoreError {
            guard case .openFailed(let code) = error else {
                check(false, "应为 openFailed，实际 \(error)")
                return
            }
            check(code == realRC, "错误码应为真实打开结果 \(realRC)，实测 \(code)（旧实现关闭后误查恒得 21）")
        }
    }

    /// 绕过生产写入契约直接插坏行（模拟历史脏数据）。仅限本套件临时库使用。
    private static func injectRawVectorRow(into dbPath: URL, id: UUID, contentHash: String = "dirty",
                                           modelVersion: String, dimension: Int32,
                                           vectorKey: Int64, blob: Data) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            preconditionFailure("测试注入库打不开")
        }
        defer { sqlite3_close_v2(db) }
        let sql = """
            INSERT INTO semantic_item(id, thought_id, content_hash, model_version, dimension,
                                      vector_key, state, priority, last_accessed_at, updated_at, vector_f16)
            VALUES(?1, ?1, ?2, ?3, ?4, ?5, 'active', 0, NULL, ?6, ?7)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            preconditionFailure("坏行 prepare 失败")
        }
        defer { sqlite3_finalize(stmt) }
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { sqlite3_bind_blob(stmt, 1, $0.baseAddress, 16, transient) }
        sqlite3_bind_text(stmt, 2, contentHash, -1, transient)
        sqlite3_bind_text(stmt, 3, modelVersion, -1, transient)
        sqlite3_bind_int(stmt, 4, dimension)
        sqlite3_bind_int64(stmt, 5, vectorKey)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { preconditionFailure("坏行插入失败") }
    }
}
