//
//  HoloPersonalContextRuntime.swift
//  Holo
//
//  通用个人情境萃取的运行时接线（实施方案 §6/P4）。
//
//  - 想法来源分页：ThoughtRepository 的 (updatedAt, id) 稳定游标（新增查询）。
//  - 落库适配：复用统一记忆仓储的 applyObservationBatch/hasSuccessfulObservation
//    作为批次 receipt；墓碑/控制态/修订目录同源。
//  - 游标与进度：UserDefaults 受保护本地状态（JSON 信封，未知键无损）。
//  - 调度门面：受 HoloPersonalContextControls.allowsExtraction 闸；前台每轮最多
//    2 包（方案 §6 初始预算）；失败不推进游标，下次续跑。
//

import CoreData
import Foundation
import OSLog

// MARK: - ThoughtRepository 游标查询（P4 分页适配）

extension ThoughtRepository {
    /// 情境萃取分页查询：(updatedAt, id) 稳定排序的 updatedAt 游标。
    /// 与 fetchAll 同一可见性口径（未删除未归档）。
    func fetchContextCandidates(
        afterUpdatedAt: Date?,
        afterID: UUID?,
        limit: Int
    ) throws -> [Thought] {
        let request = Thought.fetchRequest()
        var predicates = [NSPredicate(format: "deletedAt == nil AND isArchived == NO")]
        if let afterUpdatedAt {
            predicates.append(NSPredicate(format: "updatedAt >= %@", afterUpdatedAt as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        // 多取一页余量用于游标过滤；上限翻倍防极端同秒批量。
        request.fetchLimit = afterID == nil ? limit : limit * 2
        let results = try context.fetch(request)
        guard let afterID, let afterUpdatedAt else { return Array(results.prefix(limit)) }
        // 跳过游标位置及之前的记录（同 updatedAt 时按 id 比较）。
        let filtered = results.drop { thought in
            if thought.updatedAt < afterUpdatedAt { return true }
            if thought.updatedAt == afterUpdatedAt, thought.id.uuidString <= afterID.uuidString {
                return true
            }
            return false
        }
        return Array(filtered.prefix(limit))
    }
}

// MARK: - 想法来源分页适配

@MainActor
struct HoloThoughtContextSourcePaging: HoloContextSourcePaging {
    let repository: ThoughtRepository

    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?) {
        let thoughts = try repository.fetchContextCandidates(
            afterUpdatedAt: cursor?.updatedAt,
            afterID: cursor.map { UUID(uuidString: $0.sourceID) ?? UUID() },
            limit: limit
        )
        let filtered = thoughts.filter { thought in
            if let baseline, thought.updatedAt < baseline { return false }
            return true
        }
        let snapshots = filtered.map { thought in
            HoloContextSourceSnapshot(
                sourceID: thought.id.uuidString,
                sourceDomain: "thought",
                sourceKind: "userNote",
                revisionDigest: Self.revisionDigest(thought),
                sourceCreatedAt: thought.createdAt,
                sourceUpdatedAt: thought.updatedAt,
                plainText: HoloContextPlainTextNormalizer.normalize(thought.content).plainText,
                sensitivity: .normal,
                accessGeneration: 1
            )
        }
        guard let last = filtered.last else { return ([], nil) }
        return (snapshots, HoloContextSourceCursor(
            updatedAt: last.updatedAt,
            sourceID: last.id.uuidString
        ))
    }

    /// 与 MemorySignalDataAdapter 同式修订摘要：内容稳定摘要 + 更新时间。
    nonisolated static func revisionDigest(_ thought: Thought) -> String {
        "\(thought.updatedAt.timeIntervalSince1970)-\(HoloContextSuppressionKeys.stableDigest(thought.content))"
    }
}

// MARK: - 仓储适配（receipt/墓碑/控制态/游标）

@MainActor
struct HoloPersonalContextRuntimeWriter: HoloPersonalContextRecordWriting {
    let repository: any HoloMemoryRepository
    let thoughtRepository: ThoughtRepository
    let defaults: UserDefaults

    init(
        repository: any HoloMemoryRepository,
        thoughtRepository: ThoughtRepository = ThoughtRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.thoughtRepository = thoughtRepository
        self.defaults = defaults
    }

    private static let cursorKey = "holo_personal_context_extraction_cursor_v1"

    /// 按域游标键：thought 沿用旧键（存量零迁移）；其余域独立键（R1）。
    nonisolated static func cursorKey(domain: String) -> String {
        domain == "thought" ? cursorKey : "\(cursorKey)_\(domain)"
    }

    func existingContextRecords() async throws -> [HoloMemoryRecord] {
        // R1 四域归并：跨域候选参与同一归并池（多源聚合责任命题的基础）。
        try await repository.query(.all).filter { $0.personalContext != nil }
    }

    func write(records: [HoloMemoryRecord], batchKey: String) async throws {
        guard !records.isEmpty else {
            // 空批 receipt：用控制态通道外的最小观测键记录（复用 observation key 语义）。
            _ = try await repository.applyObservationBatch(
                [],
                observationKey: batchKey,
                domain: .thought,
                extractorVersion: 1,
                promptVersion: 1,
                completedAt: Date()
            )
            return
        }
        // R1 四域：一包候选可跨域（记录 primaryDomain 取首源域；跨域聚合/未知域回落
        // thought）。仓库按批校验 primaryDomain==domain，故按域分组、非 thought 组用
        // 「batchKey#域」组键落库；thought 组沿用父键（落成即标记父批成功）。全部组
        // 成功后对无 thought 组的批次补父键空 receipt——hasSuccessfulBatch(父键) 与重跑
        // 幂等都只看父键，部分组成功时重跑仅补缺失组（组键各自幂等）。
        let groups = Dictionary(grouping: records) { $0.primaryDomain ?? .thought }
        for (domain, group) in groups {
            _ = try await repository.applyObservationBatch(
                group,
                observationKey: domain == .thought ? batchKey : "\(batchKey)#\(domain.rawValue)",
                domain: domain,
                extractorVersion: 1,
                promptVersion: 1,
                completedAt: Date()
            )
        }
        if !groups.keys.contains(.thought) {
            _ = try await repository.applyObservationBatch(
                [],
                observationKey: batchKey,
                domain: .thought,
                extractorVersion: 1,
                promptVersion: 1,
                completedAt: Date()
            )
        }
    }

    func hasSuccessfulBatch(batchKey: String) async throws -> Bool {
        try await repository.hasSuccessfulObservation(batchKey)
    }

    func activeTombstones() async throws -> [HoloMemoryTombstone] {
        try await repository.queryTombstones()
    }

    func loadCursor() async throws -> HoloContextExtractionCursorState? {
        guard let data = defaults.data(forKey: Self.cursorKey) else { return nil }
        return try? JSONDecoder().decode(HoloContextExtractionCursorState.self, from: data)
    }

    func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws {
        let data = try JSONEncoder().encode(cursor)
        defaults.set(data, forKey: Self.cursorKey)
    }

    func loadCursor(domain: String) async throws -> HoloContextExtractionCursorState? {
        guard let data = defaults.data(forKey: Self.cursorKey(domain: domain)) else { return nil }
        return try? JSONDecoder().decode(HoloContextExtractionCursorState.self, from: data)
    }

    func saveCursor(_ cursor: HoloContextExtractionCursorState, domain: String) async throws {
        let data = try JSONEncoder().encode(cursor)
        defaults.set(data, forKey: Self.cursorKey(domain: domain))
    }

    func currentGeneration() async throws -> HoloContextExtractionGeneration {
        let control = try await repository.loadControlState()
        return HoloContextExtractionGeneration(
            userDecisionVersion: control.userDecisionVersion,
            learningBaselineAt: control.learningBaselineAt
        )
    }

    /// 修订目录：按源 ID 回查当前修订（读取后修改检测）。
    /// R1 四域：sourceKey 带域前缀分派到对应仓储；thought 存量为裸 UUID。
    @MainActor
    func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] {
        HoloLifeSourceObservation.currentRevisionDigests(sourceKeys: sourceIDs, thoughtRepository: thoughtRepository)
    }
}

// MARK: - Provider 适配

@MainActor
struct HoloPersonalContextProviderLLM: HoloPersonalContextLLMCalling {
    let provider: AIProvider

    func extract(prompt: String) async throws -> String {
        try await provider.extractPersonalContext(
            prompt: prompt,
            context: UserContext.empty // 情境萃取不注入用户档案（§9.1：不向意图识别注入私密背景）
        )
    }

    func verify(prompt: String) async throws -> String {
        try await provider.verifyPersonalContext(
            prompt: prompt,
            context: UserContext.empty
        )
    }
}

// MARK: - 调度门面

@MainActor
enum HoloPersonalContextExtractionJob {
    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "PersonalContextExtraction"
    )

    struct PassOutcome: Equatable, Sendable {
        var ranBatches = 0
        var progress = HoloContextExtractionProgress()
        var skippedReason: String?
        /// R1 四域：各域本轮流经情况（诊断/按域隔离用）。
        var domainNotes: [String: String] = [:]
    }

    /// 四域轮转指针键：保证游标公平推进（不总从同一域开始）。
    private static let roundRobinKey = "holo_personal_context_extraction_domain_pointer_v1"

    /// 一轮萃取通过调用（appLaunch/回前台触发；前台每轮最多 2 包）。
    /// R1 四域：thought/finance/task/habit 轮转，每域独立游标；单域失败不拖垮其他域（§3.11）。
    /// - Parameters:
    ///   - packageLimit: 本轮最多处理的包数（默认 2，方案 §6 前台补偿预算）。
    ///   - now: 注入时钟。
    static func runPass(
        packageLimit: Int = 2,
        provider: (any AIProvider)? = nil,
        now: Date = Date()
    ) async -> PassOutcome {
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsExtraction else {
            return PassOutcome(skippedReason: "extraction-gate-closed")
        }

        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            return PassOutcome(skippedReason: "repository-unavailable")
        }
        let llm = HoloPersonalContextProviderLLM(provider: provider ?? HoloBackendAIProvider())
        let writer = HoloPersonalContextRuntimeWriter(repository: repository)

        var outcome = PassOutcome()
        let domains = HoloLifeSourceObservation.domains
        let budget = max(packageLimit, 1)
        let defaults = UserDefaults.standard
        let pointer = max(0, defaults.integer(forKey: roundRobinKey))
        var usedBatches = 0
        var nextPointer = pointer
        // 调度语义：只有干了活的批（处理了记录或还有下一页）才消耗 LLM 预算；
        // caught-up/失败不占名额，指针最多回绕两圈防死循环。否则追平域（finance/task
        // 每轮空拉一页）会花光预算，把 more 域（如 thought 有存货）系统性饿死
        //（2026-09-23 实测：thought=more 连续两次启动零消化）。
        var offset = 0
        while usedBatches < budget, offset < domains.count * 2 {
            let domain = domains[(pointer + offset) % domains.count]
            offset += 1
            guard let paging = HoloLifeSourceObservation.makePaging(domain: domain) else {
                outcome.domainNotes[domain] = "paging-unavailable"
                continue
            }
            let extractor = HoloPersonalContextExtractor(
                paging: paging,
                llm: llm,
                writer: writer,
                domain: domain
            )
            do {
                let batch = try await extractor.runOneBatch(now: now)
                outcome.ranBatches += 1
                let consumedBudget = batch.hasMore
                    || batch.createdRecords + batch.mergedRecords + batch.suppressed + batch.discarded > 0
                if consumedBudget { usedBatches += 1 }
                if let cursor = try? await writer.loadCursor(domain: domain) {
                    outcome.progress = outcome.progress.byAdding(cursor.progress)
                }
                outcome.domainNotes[domain] = batch.hasMore ? "more" : "caught-up"
                nextPointer = (pointer + offset) % domains.count
            } catch {
                // 按域隔离：失败只影响本域本批，游标本域不推进，下轮重试；继续其他域。
                outcome.progress.failedBatches += 1
                outcome.domainNotes[domain] = "failed:\(String(describing: type(of: error)))"
            }
        }
        defaults.set(nextPointer, forKey: roundRobinKey)
        logger.error("EXTRACT-DIAG ran=\(outcome.ranBatches) created=\(outcome.progress.createdRecords) suppressed=\(outcome.progress.suppressedCandidates) failed=\(outcome.progress.failedBatches) domains=\(outcome.domainNotes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","), privacy: .public)")
        HoloPersonalContextDiagnostics.recordExtraction(outcome)
        return outcome
    }
}

// MARK: - 链路诊断快照

/// 情境链路最近一次状态的本地快照（UserDefaults JSON）：
/// 供「AI 记忆实验室」展示与走查定位——萃取是否在跑、库里有多少、上次规划检索到多少。
nonisolated struct HoloPersonalContextDiagnosticsSnapshot: Codable, Equatable, Sendable {
    var lastExtractionAt: Date?
    var lastExtractionRanBatches: Int?
    var lastExtractionCreatedTotal: Int?
    var lastExtractionSkipReason: String?
    /// 最近一次规划时的库内情境条数。
    var lastPlanningContextCount: Int?
    var lastPlanningAt: Date?
    var lastPlanningCandidates: Int?
    var lastPlanningSelected: Int?
    var lastPlanningCoverage: String?
    var lastPlanningRawFallbackUsed: Bool?
    var lastPlanningGateClosed: Bool?
}

nonisolated enum HoloPersonalContextDiagnostics {
    static let storageKey = "holo_personal_context_diagnostics_v1"

    static func load(defaults: UserDefaults = .standard) -> HoloPersonalContextDiagnosticsSnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(HoloPersonalContextDiagnosticsSnapshot.self, from: data)
        else { return HoloPersonalContextDiagnosticsSnapshot() }
        return snapshot
    }

    static func save(
        _ mutate: (inout HoloPersonalContextDiagnosticsSnapshot) -> Void,
        defaults: UserDefaults = .standard
    ) {
        var snapshot = load(defaults: defaults)
        mutate(&snapshot)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func recordExtraction(_ outcome: HoloPersonalContextExtractionJob.PassOutcome, defaults: UserDefaults = .standard) {
        save({ snapshot in
            snapshot.lastExtractionAt = Date()
            snapshot.lastExtractionRanBatches = outcome.ranBatches
            snapshot.lastExtractionCreatedTotal = outcome.progress.createdRecords
            snapshot.lastExtractionSkipReason = outcome.skippedReason
        }, defaults: defaults)
    }

    static func recordPlanningGateClosed(defaults: UserDefaults = .standard) {
        save({ snapshot in
            snapshot.lastPlanningAt = Date()
            snapshot.lastPlanningGateClosed = true
        }, defaults: defaults)
    }

    static func recordPlanning(
        contextCount: Int,
        candidates: Int,
        selected: Int,
        coverage: String,
        rawFallbackUsed: Bool,
        defaults: UserDefaults = .standard
    ) {
        save({ snapshot in
            snapshot.lastPlanningAt = Date()
            snapshot.lastPlanningGateClosed = false
            snapshot.lastPlanningContextCount = contextCount
            snapshot.lastPlanningCandidates = candidates
            snapshot.lastPlanningSelected = selected
            snapshot.lastPlanningCoverage = coverage
            snapshot.lastPlanningRawFallbackUsed = rawFallbackUsed
        }, defaults: defaults)
    }
}

// MARK: - 生命周期调度

/// 情境萃取的生命周期调度门面：appLaunch/回前台触发。
/// 冷启动不走防抖：每天首次打开即补萃取新想法，追平后仅本地对账零 LLM 成本；
/// 回前台 30 分钟防抖。手动触发（实验室按钮）绕过防抖；闸门由 runPass 内部allowsExtraction把守。
@MainActor
enum HoloPersonalContextExtractionScheduler {
    private static let lastPassAtKey = "holo_personal_context_extraction_last_pass_at_v1"
    /// 防抖间隔：两次前台萃取之间的最小间隔。
    static let minimumInterval: TimeInterval = 30 * 60

    static func runPassIfDue(bypassDebounce: Bool = false, packageLimit: Int = 2) async {
        let defaults = UserDefaults.standard
        if !bypassDebounce, let last = defaults.object(forKey: lastPassAtKey) as? Date,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        defaults.set(Date(), forKey: lastPassAtKey)
        _ = await HoloPersonalContextExtractionJob.runPass(packageLimit: packageLimit)
    }
}
