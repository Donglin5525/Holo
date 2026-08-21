//
//  HoloReplayDigestService.swift
//  Holo
//
//  周期回放历史归纳的远期摘要维护。
//
//  设计（见方案 §D3/D4）：
//  - 一份**全局**累计摘要（跨周期类型合并），存 JSON。
//  - 每次生成本期回放后，监听 .memoryInsightDidGenerate 异步触发 consolidate：
//    oldDigest + 本期 payload → 轻量 AI → 新 digest → 写盘。
//  - 失败仅 log，不阻塞主回放流程。
//  - 老用户首次升级时 backfillIfNeeded 把历史回放批量归纳成 seed digest。
//

import Foundation
import os.log

// MARK: - Persisted Model

/// 持久化的累计摘要模型（存 Application Support/Holo/HoloReplayDigest.json）
struct HoloReplayDigestModel: Codable, Equatable {
    /// 累计摘要正文（≤400 字，按时间正序）
    var cumulativeDigest: String?
    /// 摘要覆盖的最早日期
    var coveredRangeStart: Date?
    /// 摘要覆盖的最晚日期
    var coveredRangeEnd: Date?
    /// 长期稳定模式（AI 维护）
    var keyPatterns: [ReplayKeyPattern]
    /// 用户在追踪的目标（AI 维护）
    var trackedGoals: [ReplayTrackedGoal]
    /// 已并入摘要的回放总数
    var sourceInsightCount: Int
    /// 已并入摘要的回放 ID（去重，防止同一期被重复 consolidate）
    var sourceInsightIDs: [String]
    /// 摘要 prompt 版本（prompt 升级时可据此作废旧摘要）
    var digestVersion: Int
    /// 最后更新时间
    var lastUpdatedAt: Date?
    /// 历史回填格式失败次数；达到上限后跳过该期，避免每次启动反复请求同一坏数据。
    var backfillFailureCounts: [String: Int]? = nil
    /// 回填撞 429（配额耗尽）后的冷却到期时间。冷却期内跳过整批扫描，
    /// 避免每次启动/回前台都从头扫一遍再撞墙（冗余请求 + 刷屏日志）。
    /// 用 UTC 日期对齐后端配额窗口（后端日切为北京 08:00 = UTC 00:00）。
    var backfillRateLimitCooldownUntil: Date? = nil

    static func empty() -> HoloReplayDigestModel {
        HoloReplayDigestModel(
            cumulativeDigest: nil,
            coveredRangeStart: nil,
            coveredRangeEnd: nil,
            keyPatterns: [],
            trackedGoals: [],
            sourceInsightCount: 0,
            sourceInsightIDs: [],
            digestVersion: 1,
            lastUpdatedAt: nil
        )
    }
}

/// AI consolidate 调用的输出契约（对应后端 replay_digest_consolidation 的 JSON Schema）
private struct ReplayDigestAIOutput: Codable {
    let cumulativeDigest: String?
    let coveredRangeStart: String?      // YYYY-MM-DD
    let coveredRangeEnd: String?        // YYYY-MM-DD
    let keyPatterns: [AIKeyPattern]?
    let trackedGoals: [AITrackedGoal]?

    struct AIKeyPattern: Codable {
        let pattern: String?
        let periods: String?
    }
    struct AITrackedGoal: Codable {
        let goalName: String?
        let status: String?
        let latestNote: String?
    }
}

// MARK: - Service

final class HoloReplayDigestService {
    static let shared = HoloReplayDigestService()

    private static let logger = Logger(subsystem: "com.holo.app", category: "HoloReplayDigest")

    /// 回填触发阈值：历史回放少于该数不回填（远期摘要价值不足）
    private static let backfillThreshold = 4
    /// 每次前台最多回填 4 期，减少启动阶段网络占用。
    private static let backfillBatchSize = 4
    private static let maxBackfillFailuresPerInsight = 2
    /// 撞 429 后的冷却时长：覆盖一个后端配额日窗口（北京 08:00 切分）。
    /// 取略多于 24h，保证无论何时撞墙，下一个窗口开始前都不会再扫。
    private static let backfillRateLimitCooldown: TimeInterval = 25 * 60 * 60

    /// ISO8601 日期格式化（请求体里统一用这个，去掉小数秒避免后端解析歧义）
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("HoloReplayDigest.json")
    }()

    /// 内存缓存，避免 builder 每次读盘。init 时同步加载。
    private(set) var model: HoloReplayDigestModel

    /// 单线程消费队列；新回放不会因为已有 consolidate 正在执行而被丢弃。
    private var isConsolidating = false
    private var pendingConsolidations: [PendingConsolidation] = []
    /// 用户主动回放优先，历史归纳只在没有用户任务时运行。
    private var activeUserReplayIDs: Set<UUID> = []

    private init() {
        model = Self.loadFromDisk(fileURL: fileURL) ?? .empty()
    }

    /// Builder 读取入口：返回当前累计摘要的只读快照（用于构造 ReplayHistory.cumulativeDigest）
    var currentSnapshot: HoloReplayDigestModel { model }

    func beginUserReplay(messageId: UUID) {
        activeUserReplayIDs.insert(messageId)
    }

    func endUserReplay(messageId: UUID, resumeQueuedDigest: Bool = true) {
        activeUserReplayIDs.remove(messageId)
        guard resumeQueuedDigest,
              activeUserReplayIDs.isEmpty,
              !pendingConsolidations.isEmpty else { return }
        Task { await drainConsolidationQueue() }
    }

    // MARK: - Consolidate (single replay)

    /// 把一期新回放并入累计摘要。
    /// - Note: 失败仅 log 不抛，调用方（observer）无需 try。
    func consolidate(
        payload: MemoryInsightPayload,
        insightID: String,
        periodType: MemoryInsightPeriodType,
        periodStart: Date,
        periodEnd: Date
    ) async {
        // 1. 去重：同一期已并入或已排队则跳过
        if model.sourceInsightIDs.contains(insightID) {
            Self.logger.debug("回放 \(insightID) 已在摘要中，跳过 consolidate")
            return
        }
        guard !pendingConsolidations.contains(where: { $0.insightID == insightID }) else {
            Self.logger.debug("回放 \(insightID) 已在摘要队列中，跳过去重")
            return
        }

        // 2. consent 前置校验（避免无意义发起请求）
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            Self.logger.debug("数据处理授权未开启，跳过 consolidate")
            return
        }

        pendingConsolidations.append(PendingConsolidation(
            payload: payload,
            insightID: insightID,
            periodType: periodType,
            periodStart: periodStart,
            periodEnd: periodEnd
        ))
        Self.logger.info("回放摘要已排队（待处理 \(self.pendingConsolidations.count) 期）")
        await drainConsolidationQueue()
    }

    // MARK: - Backfill (legacy users)

    /// 老用户首次升级时，若磁盘无有效摘要且历史回放充足，批量归纳成 seed digest。
    /// - Note: 失败仅 log，不阻塞启动。重复调用安全（已有有效摘要则跳过）。
    func backfillIfNeeded(historyRepo: MemoryInsightRepository) async {
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else { return }
        // 冷却短路：上次撞 429 后，冷却期内不再扫描，避免每次启动冗余请求。
        if let cooldownUntil = model.backfillRateLimitCooldownUntil,
           Date() < cooldownUntil {
            Self.logger.info("回填处于 429 冷却期（至 \(cooldownUntil)），跳过本次扫描")
            return
        }
        guard activeUserReplayIDs.isEmpty else {
            Self.logger.info("用户周期回放正在生成，暂停历史摘要回填")
            return
        }
        // 先消费运行期积压，再做历史扫描；二者共享同一写入通道。
        await drainConsolidationQueue()
        guard pendingConsolidations.isEmpty else { return }

        let all = historyRepo.fetchAllReadyInsightsAcrossPeriods()
        guard all.count >= Self.backfillThreshold || model.sourceInsightCount > 0 else {
            Self.logger.info("历史回放不足 \(Self.backfillThreshold) 期（\(all.count)），跳过回填")
            return
        }
        guard !isConsolidating else { return }
        isConsolidating = true
        defer {
            isConsolidating = false
            if activeUserReplayIDs.isEmpty, !pendingConsolidations.isEmpty {
                Task { await drainConsolidationQueue() }
            }
        }

        let failures = model.backfillFailureCounts ?? [:]
        let remaining = all.filter { insight in
            !model.sourceInsightIDs.contains(insight.id.uuidString)
                && failures[insight.id.uuidString, default: 0] < Self.maxBackfillFailuresPerInsight
        }
        guard !remaining.isEmpty else { return }

        let batch = Array(remaining.prefix(Self.backfillBatchSize))
        Self.logger.info(
            "开始回填累计摘要（本批 \(batch.count) 期，剩余 \(remaining.count) 期）"
        )
        var skippedInvalidPayloadCount = 0
        for insight in batch {
            guard activeUserReplayIDs.isEmpty else {
                Self.logger.info("用户周期回放开始，暂停本批历史摘要回填")
                break
            }
            guard let payload = insight.parsedPayload else {
                skippedInvalidPayloadCount += 1
                var counts = model.backfillFailureCounts ?? [:]
                counts[insight.id.uuidString, default: 0] += 1
                model.backfillFailureCounts = counts
                saveToDisk()
                Self.logger.error(
                    "回填跳过不可解析洞察（\(insight.id)，第 \(counts[insight.id.uuidString, default: 0]) 次）：缺少有效 cardsJSON"
                )
                continue
            }
            do {
                model = try await callConsolidateAI(
                    oldDigest: model,
                    newReplay: payload,
                    periodType: MemoryInsightPeriodType(rawValue: insight.periodType) ?? .custom,
                    periodStart: insight.periodStart,
                    periodEnd: insight.periodEnd
                )
                model.sourceInsightIDs.append(insight.id.uuidString)
                model.sourceInsightCount = model.sourceInsightIDs.count
                model.lastUpdatedAt = Date()
                var counts = model.backfillFailureCounts ?? [:]
                counts[insight.id.uuidString] = nil
                model.backfillFailureCounts = counts
                saveToDisk()
                Self.logger.info("回填断点已保存（累计 \(self.model.sourceInsightCount) 期）")
            } catch {
                // 撞 429（配额耗尽）：剩余配额一定也不够，立刻 break 整批，
                // 并写入冷却，避免每次启动/回前台都从头扫一遍再撞墙。
                // 额度 429 带 quota 错误体时 APIClient 抛 HoloQuotaError 而非
                // APIError.rateLimited，两种形态都要进冷却。
                var isQuotaRejection = error is HoloQuotaError
                if case .rateLimited? = error as? APIError {
                    isQuotaRejection = true
                }
                if isQuotaRejection {
                    model.backfillRateLimitCooldownUntil =
                        Date().addingTimeInterval(Self.backfillRateLimitCooldown)
                    saveToDisk()
                    Self.logger.error(
                        "回填撞配额上限，本批中止并进入冷却 25h（已回填 \(self.model.sourceInsightCount) 期）"
                    )
                    break
                }
                var counts = model.backfillFailureCounts ?? [:]
                counts[insight.id.uuidString, default: 0] += 1
                model.backfillFailureCounts = counts
                saveToDisk()
                Self.logger.error(
                    "回填单期失败（\(insight.id)，第 \(counts[insight.id.uuidString, default: 0]) 次）：\(error.localizedDescription)"
                )
            }
        }
        let skippedSuffix = skippedInvalidPayloadCount > 0
            ? "，跳过不可解析 \(skippedInvalidPayloadCount) 期"
            : ""
        Self.logger.info(
            "本批回放摘要回填结束（累计 \(self.model.sourceInsightCount) 期\(skippedSuffix)）"
        )
    }

    // MARK: - AI Call

    /// 调后端 replayDigest purpose，把本期回放并入累计摘要。
    private func callConsolidateAI(
        oldDigest: HoloReplayDigestModel,
        newReplay: MemoryInsightPayload,
        periodType: MemoryInsightPeriodType,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> HoloReplayDigestModel {
        let provider = await MainActor.run { HoloBackendEnvironment.makeDefaultProvider() }
        guard let backendProvider = provider as? HoloBackendAIProvider else {
            throw APIError.serverError("当前 Provider 不支持回放摘要 consolidate")
        }

        // 组装 user message：oldDigest + newReplay 的结构化 JSON
        let requestPayload = ConsolidateRequest(
            oldDigest: oldDigest.cumulativeDigest,
            oldCoveredRangeStart: oldDigest.coveredRangeStart.map { Self.isoFormatter.string(from: $0) },
            oldCoveredRangeEnd: oldDigest.coveredRangeEnd.map { Self.isoFormatter.string(from: $0) },
            oldKeyPatterns: oldDigest.keyPatterns,
            oldTrackedGoals: oldDigest.trackedGoals,
            newReplay: ConsolidateRequest.NewReplay(
                periodType: periodType.rawValue,
                periodStart: Self.isoFormatter.string(from: periodStart),
                periodEnd: Self.isoFormatter.string(from: periodEnd),
                title: newReplay.title,
                summary: newReplay.summary,
                keyCardTitles: newReplay.cards.prefix(5).map(\.title),
                suggestedQuestions: Array(newReplay.suggestedQuestions.prefix(3)),
                anomalyHighlights: newReplay.cards.filter { $0.type == .anomaly }.map(\.title)
            )
        )

        let requestData = try JSONEncoder().encode(requestPayload)
        let requestJSON = String(data: requestData, encoding: .utf8) ?? "{}"

        let messages: [ChatMessageDTO] = [.user(requestJSON)]
        let raw = try await backendProvider.chat(messages: messages, purpose: .replayDigest)

        return try parseConsolidateOutput(raw: raw, previous: oldDigest)
    }

    /// 解析 AI 返回的 JSON，落到持久化模型。解析失败的字段回退用旧值。
    private func parseConsolidateOutput(raw: String, previous: HoloReplayDigestModel) throws -> HoloReplayDigestModel {
        // 容错：AI 偶尔会用 ```json 围栏包裹
        let cleaned = raw
            .replacingOccurrences(of: "^```json\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^```\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates = [cleaned]
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            let braces = String(cleaned[start...end])
            if braces != cleaned {
                candidates.append(braces)
            }
        }
        let output = candidates.lazy.compactMap { candidate -> ReplayDigestAIOutput? in
            guard let data = candidate.data(using: .utf8) else { return nil }
            if let strict = try? JSONDecoder().decode(ReplayDigestAIOutput.self, from: data) {
                return strict
            }
            // 单个非关键字段类型偶发漂移时保住主摘要，避免整期回填失败。
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let patterns = (object["keyPatterns"] as? [[String: Any]])?.map { item in
                ReplayDigestAIOutput.AIKeyPattern(
                    pattern: item["pattern"] as? String,
                    periods: item["periods"] as? String
                )
            }
            let goals = (object["trackedGoals"] as? [[String: Any]])?.map { item in
                ReplayDigestAIOutput.AITrackedGoal(
                    goalName: item["goalName"] as? String,
                    status: item["status"] as? String,
                    latestNote: item["latestNote"] as? String
                )
            }
            return ReplayDigestAIOutput(
                cumulativeDigest: object["cumulativeDigest"] as? String,
                coveredRangeStart: object["coveredRangeStart"] as? String,
                coveredRangeEnd: object["coveredRangeEnd"] as? String,
                keyPatterns: patterns,
                trackedGoals: goals
            )
        }.first
        guard let output,
              let cumulativeDigest = output.cumulativeDigest?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !cumulativeDigest.isEmpty else {
            throw APIError.serverError("回放摘要返回格式不正确")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter() // 无小数秒兜底
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        func parse(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            return formatter.date(from: s)
                ?? fallbackFormatter.date(from: s)
                ?? dayFormatter.date(from: s)
        }

        return HoloReplayDigestModel(
            cumulativeDigest: cumulativeDigest,
            coveredRangeStart: parse(output.coveredRangeStart) ?? previous.coveredRangeStart,
            coveredRangeEnd: parse(output.coveredRangeEnd) ?? previous.coveredRangeEnd,
            keyPatterns: output.keyPatterns.map { items in
                items.compactMap { item -> ReplayKeyPattern? in
                    guard let pattern = item.pattern, !pattern.isEmpty else { return nil }
                    return ReplayKeyPattern(pattern: pattern, periods: item.periods ?? "")
                }
            } ?? previous.keyPatterns,
            trackedGoals: output.trackedGoals.map { items in
                items.compactMap { item -> ReplayTrackedGoal? in
                    guard let name = item.goalName, !name.isEmpty else { return nil }
                    return ReplayTrackedGoal(
                        goalName: name,
                        status: item.status ?? "stalled",
                        latestNote: item.latestNote ?? ""
                    )
                }
            } ?? previous.trackedGoals,
            sourceInsightCount: previous.sourceInsightCount,
            sourceInsightIDs: previous.sourceInsightIDs,
            digestVersion: max(previous.digestVersion, 1),
            lastUpdatedAt: previous.lastUpdatedAt,
            backfillFailureCounts: previous.backfillFailureCounts,
            backfillRateLimitCooldownUntil: previous.backfillRateLimitCooldownUntil
        )
    }

    private func drainConsolidationQueue() async {
        guard !isConsolidating, activeUserReplayIDs.isEmpty else { return }
        isConsolidating = true
        defer { isConsolidating = false }

        while !pendingConsolidations.isEmpty, activeUserReplayIDs.isEmpty {
            let pending = pendingConsolidations.removeFirst()
            if model.sourceInsightIDs.contains(pending.insightID) {
                continue
            }
            do {
                model = try await callConsolidateAI(
                    oldDigest: model,
                    newReplay: pending.payload,
                    periodType: pending.periodType,
                    periodStart: pending.periodStart,
                    periodEnd: pending.periodEnd
                )
                model.sourceInsightIDs.append(pending.insightID)
                model.sourceInsightCount = model.sourceInsightIDs.count
                model.lastUpdatedAt = Date()
                saveToDisk()
                Self.logger.info("回放摘要已更新（累计 \(self.model.sourceInsightCount) 期）")
            } catch {
                // 保留队首，等下一次前台/新回放触发再试，避免本轮无限循环。
                pendingConsolidations.insert(pending, at: 0)
                Self.logger.error("回放摘要 consolidate 失败，已保留待重试：\(error.localizedDescription)")
                break
            }
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(model) else {
            Self.logger.error("回放摘要编码失败")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk(fileURL: URL) -> HoloReplayDigestModel? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(HoloReplayDigestModel.self, from: data)
    }
}

private struct PendingConsolidation {
    let payload: MemoryInsightPayload
    let insightID: String
    let periodType: MemoryInsightPeriodType
    let periodStart: Date
    let periodEnd: Date
}

// MARK: - AI Request Payload

private struct ConsolidateRequest: Encodable {
    struct NewReplay: Encodable {
        let periodType: String
        let periodStart: String
        let periodEnd: String
        let title: String
        let summary: String
        let keyCardTitles: [String]
        let suggestedQuestions: [String]
        let anomalyHighlights: [String]
    }
    let oldDigest: String?
    let oldCoveredRangeStart: String?
    let oldCoveredRangeEnd: String?
    let oldKeyPatterns: [ReplayKeyPattern]
    let oldTrackedGoals: [ReplayTrackedGoal]
    let newReplay: NewReplay
}

// MARK: - Observer

/// 监听 .memoryInsightDidGenerate，异步触发累计摘要 consolidate。
/// - Important: 必须在 App 启动时调用 `startObserving()` 注册（参照 HoloWidgetSnapshotService）。
enum HoloReplayDigestObserver {
    private static let logger = Logger(subsystem: "com.holo.app", category: "HoloReplayDigestObserver")
    private static var observer: NSObjectProtocol?

    static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .memoryInsightDidGenerate,
            object: nil,
            queue: OperationQueue()
        ) { notification in
            handle(notification)
        }
        logger.info("已开始监听周期回放生成事件")
    }

    static func stopObserving() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }

    private static func handle(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        guard let insightID = userInfo["insightID"] as? String,
              let payload = userInfo["payload"] as? MemoryInsightPayload,
              let periodTypeRaw = userInfo["periodType"] as? String,
              let periodStart = userInfo["periodStart"] as? Date,
              let periodEnd = userInfo["periodEnd"] as? Date,
              let periodType = MemoryInsightPeriodType(rawValue: periodTypeRaw) else {
            logger.debug("回放摘要 observer：通知字段缺失，跳过")
            return
        }
        // 后台队列回调 → 开 Task 调 async AI，do/catch 隔离错误
        Task {
            await HoloReplayDigestService.shared.consolidate(
                payload: payload,
                insightID: insightID,
                periodType: periodType,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }
    }
}
