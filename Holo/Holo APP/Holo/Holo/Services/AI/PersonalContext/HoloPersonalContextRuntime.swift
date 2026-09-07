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

    func existingContextRecords() async throws -> [HoloMemoryRecord] {
        try await repository.query(.domain(.thought)).filter { $0.personalContext != nil }
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
        _ = try await repository.applyObservationBatch(
            records,
            observationKey: batchKey,
            domain: .thought,
            extractorVersion: 1,
            promptVersion: 1,
            completedAt: Date()
        )
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

    func currentGeneration() async throws -> HoloContextExtractionGeneration {
        let control = try await repository.loadControlState()
        return HoloContextExtractionGeneration(
            userDecisionVersion: control.userDecisionVersion,
            learningBaselineAt: control.learningBaselineAt
        )
    }

    /// 修订目录：按源 ID 回查当前修订（读取后修改检测）。
    func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] {
        var revisions: [String: String] = [:]
        for sourceID in sourceIDs {
            guard let uuid = UUID(uuidString: sourceID),
                  let thought = try thoughtRepository.fetchById(uuid) else {
                // 来源已删除：返回哨兵修订，触发过期批次拒绝（删除路径走失效传播）。
                revisions[sourceID] = "deleted"
                continue
            }
            revisions[sourceID] = HoloThoughtContextSourcePaging.revisionDigest(thought)
        }
        return revisions
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
    }

    /// 一轮萃取通过调用（appLaunch/回前台触发；前台每轮最多 2 包）。
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
        let extractor = HoloPersonalContextExtractor(
            paging: HoloThoughtContextSourcePaging(repository: ThoughtRepository()),
            llm: HoloPersonalContextProviderLLM(provider: provider ?? HoloBackendAIProvider()),
            writer: HoloPersonalContextRuntimeWriter(repository: repository)
        )

        var outcome = PassOutcome()
        do {
            for _ in 0..<max(packageLimit, 1) {
                let batch = try await extractor.runOneBatch(now: now)
                outcome.ranBatches += 1
                if let cursor = try? await HoloPersonalContextRuntimeWriter(repository: repository)
                    .loadCursor() {
                    outcome.progress = cursor.progress
                }
                if !batch.hasMore { break }
            }
        } catch {
            // 失败不推进游标（runOneBatch 内部保证）；如实记录，下次续跑。
            logger.info("萃取批次失败，游标未推进：\(String(describing: error), privacy: .public)")
            if let cursor = try? await HoloPersonalContextRuntimeWriter(repository: repository)
                .loadCursor() {
                outcome.progress = cursor.progress
            }
            outcome.progress.failedBatches += 1
        }
        logger.error("EXTRACT-DIAG ran=\(outcome.ranBatches) created=\(outcome.progress.createdRecords) suppressed=\(outcome.progress.suppressedCandidates) failed=\(outcome.progress.failedBatches) skip=\(outcome.skippedReason ?? "none")")
        return outcome
    }
}
