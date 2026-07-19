//
//  HoloMemoryObserverService.swift
//  Holo
//
//  Memory Observer 调度器：组装观察包 → 调用 LLM → 解析 → 校验 → 应用
//

import Foundation
import OSLog

protocol HoloDomainMemoryLLMClient: Sendable {
    func extract(
        request: HoloDomainObservationRequest,
        domain: HoloMemoryDomain
    ) async throws -> Data
}

#if !HOLO_MEMORY_STANDALONE
struct HoloBackendDomainMemoryLLMClient: HoloDomainMemoryLLMClient {
    func extract(
        request: HoloDomainObservationRequest,
        domain: HoloMemoryDomain
    ) async throws -> Data {
        let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
        // Release Prompt 由后端 purpose 注入；客户端只发送结构化 JSON data。
        let response = try await provider.chat(
            messages: [.user(request.userDataJSON)],
            purpose: .memoryDomainExtraction
        )
        return Data(response.utf8)
    }
}
#endif

struct HoloDomainObservationRunInput: Sendable {
    var package: HoloDomainObservationPackage
    var observationKey: String
    var extractorVersion: Int
    var promptVersion: Int
}

enum HoloDomainObservationRunResult: Equatable, Sendable {
    case succeeded(domain: HoloMemoryDomain, writtenCount: Int)
    case skippedDuplicate(domain: HoloMemoryDomain)
    case rejected(domain: HoloMemoryDomain, count: Int)
    case failed(domain: HoloMemoryDomain)
    case denied(domain: HoloMemoryDomain)
}

struct HoloDomainMemoryObserverExecutor {
    typealias StoreProvider = @Sendable () async throws -> any HoloDomainMemoryObservationStore
    typealias AccessProvider = @Sendable () async -> Bool

    private let client: any HoloDomainMemoryLLMClient
    private let storeProvider: StoreProvider
    private let accessProvider: AccessProvider
    private let logger = Logger(subsystem: "com.holo.app", category: "DomainMemoryObserver")

    init(
        client: any HoloDomainMemoryLLMClient,
        storeProvider: @escaping StoreProvider,
        accessProvider: @escaping AccessProvider
    ) {
        self.client = client
        self.storeProvider = storeProvider
        self.accessProvider = accessProvider
    }

    #if !HOLO_MEMORY_STANDALONE
    static var live: HoloDomainMemoryObserverExecutor {
        HoloDomainMemoryObserverExecutor(
            client: HoloBackendDomainMemoryLLMClient(),
            storeProvider: { try await HoloMemoryRuntime.shared.repository() },
            accessProvider: {
                await MainActor.run {
                    HoloMemoryAccessPolicy.current.extractionDecision(for: .externalAI) == .allowedExternalAI
                }
            }
        )
    }
    #endif

    func run(
        _ inputs: [HoloDomainObservationRunInput],
        now: Date = Date()
    ) async -> [HoloDomainObservationRunResult] {
        var results: [HoloDomainObservationRunResult] = []
        for input in inputs {
            let domain = input.package.domain
            guard await accessProvider() else {
                results.append(.denied(domain: domain))
                continue
            }
            do {
                let store = try await storeProvider()
                if try await store.hasSuccessfulObservation(input.observationKey) {
                    results.append(.skippedDuplicate(domain: domain))
                    continue
                }
                let request = try HoloDomainObservationPackageBuilder.makeRequest(input.package)
                let raw = try await client.extract(request: request, domain: domain)
                let validation = HoloDomainMemoryOutputValidator.decodeAndValidate(
                    raw, against: input.package, now: now,
                    extractorVersion: input.extractorVersion,
                    promptVersion: input.promptVersion
                )
                guard validation.rejections.isEmpty else {
                    logger.warning("领域记忆输出被 Validator 拒绝：domain=\(domain.rawValue, privacy: .public), count=\(validation.rejections.count, privacy: .public)")
                    results.append(.rejected(domain: domain, count: validation.rejections.count))
                    continue
                }
                let upserts = try await HoloDomainMemoryObservationApplier.apply(
                    validation,
                    to: store,
                    observationKey: input.observationKey,
                    domain: domain,
                    extractorVersion: input.extractorVersion,
                    promptVersion: input.promptVersion,
                    completedAt: now
                )
                let written = upserts.filter { $0 == .inserted || $0 == .updated }.count
                results.append(.succeeded(domain: domain, writtenCount: written))
            } catch {
                // 不记录模型原文或用户数据，只保留领域和错误类型。
                logger.error("领域记忆观察失败：domain=\(domain.rawValue, privacy: .public), errorType=\(String(describing: type(of: error)), privacy: .public)")
                results.append(.failed(domain: domain))
            }
        }
        return results
    }
}

#if !HOLO_MEMORY_STANDALONE
final class HoloMemoryObserverService {

    static let shared = HoloMemoryObserverService()

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryObserver")

    private init() {}

    func runDomainObservations(
        _ inputs: [HoloDomainObservationRunInput],
        now: Date = Date()
    ) async -> [HoloDomainObservationRunResult] {
        await HoloDomainMemoryObserverExecutor.live.run(inputs, now: now)
    }

    /// 执行一次完整观察
    func runObservation(
        habitSummaries: [HabitFocusSummary],
        goalInputs: [GoalProgressInput]
    ) async {
        // 1. 所有外部 AI 记忆萃取统一经过权限策略，避免服务自行旁路开关或数据授权。
        guard HoloMemoryAccessPolicy.current.extractionDecision(for: .externalAI) == .allowedExternalAI else {
            logger.info("Memory Observer 被统一权限策略阻止")
            return
        }

        // 2. 先过期超期记忆
        let expiredIDs = HoloEpisodicMemoryStore.shared.markExpired()
        if !expiredIDs.isEmpty {
            logger.info("标记 \(expiredIDs.count) 条情景记忆为过期")
        }

        // 3. 构建信号
        let habitSignals = HabitMemorySignalBuilder.buildSignals(from: habitSummaries)
        let goalSignals = GoalMemorySignalBuilder.buildSignals(from: goalInputs)

        guard !habitSignals.isEmpty || !goalSignals.isEmpty else {
            logger.info("无有效信号，跳过观察")
            return
        }

        logger.info("信号生成完成: \(habitSignals.count) 条习惯信号, \(goalSignals.count) 条目标信号")

        // 4. 组装观察包
        let package = HoloObservationPackageBuilder.buildPackage(
            habitSignals: habitSignals,
            goalSignals: goalSignals,
            existingEpisodicMemories: HoloEpisodicMemoryStore.shared.load(),
            existingLongTermMemories: HoloLongTermMemoryStore.load(),
            suppressionRules: HoloEpisodicMemoryStore.shared.loadSuppressionRules()
        )

        // 5. 调用 LLM
        let userMessage = encodePackageAsUserMessage(package)
        let rawResponse: String
        do {
            rawResponse = try await callObserverLLM(userMessage: userMessage)
        } catch {
            logger.error("Observer LLM 调用失败: \(error.localizedDescription)")
            return
        }

        // 6. 解析
        guard let output = HoloMemoryObserverResponseParser.parse(rawResponse) else {
            logger.error("Observer 输出解析失败")
            return
        }

        logger.info("Observer 解析完成: \(output.newEpisodicMemories.count) 新记忆候选, \(output.memoryHits.count) 命中, \(output.weakenedOrExpiredMemories.count) 弱化")

        // 7. 校验
        let validationResult = MemoryObserverOutputValidator.validate(
            output,
            against: package,
            suppressionRules: HoloEpisodicMemoryStore.shared.loadSuppressionRules()
        )

        logger.info("Observer 校验结果: \(validationResult.validNewMemories.count) 有效, \(validationResult.rejectedEntries.count) 被拒绝")

        // 8. 应用
        let applier = HoloMemoryObservationApplier()
        let result = applier.apply(
            validationResult: validationResult,
            runID: package.runID
        )

        logger.info("Observer 应用结果: \(result.newCount) 新增, \(result.hitCount) 命中, \(result.expiredCount) 过期")

        // 9. 记录 run 结果
        saveRunRecord(
            runID: package.runID,
            signalCount: habitSignals.count + goalSignals.count,
            result: result,
            rejectedCount: validationResult.rejectedEntries.count
        )

        // 10. Tier 2 触发策略（Phase 6.4，agentObserverTier2Enabled 灰度）
        // 联动主闸：agentRuntimeEnabled 关闭时 Tier2 也不触发，避免 Observer 旁路总闸（Phase 2 §5.2）
        if HoloAIFeatureFlags.agentObserverTier2Enabled && HoloAIFeatureFlags.agentRuntimeEnabled {
            triggerTier2IfNeeded(goalSignalCount: goalSignals.count)
        }
    }

    /// Tier 2 触发：发现目标信号（goalConflict）且冷却已过时，升级到深度 Agent。
    /// patterns 由目标信号数量确定性构造（Observer 不跑工具，故不用 PatternMiner）；
    /// 冷却时间持久化在 UserDefaults。Tier2 Agent 在 @MainActor Task 中异步跑（fire-and-forget），不阻塞 Observer。
    private func triggerTier2IfNeeded(goalSignalCount: Int, now: Date = Date()) {
        let patterns: [HoloPatternSignal] = goalSignalCount > 0 ? [
            HoloPatternSignal(
                id: "observer-goalConflict",
                type: .goalConflict,
                title: "目标进度观察",
                metricKey: "observer.goal",
                value: nil, baselineValue: nil,
                severity: .high,
                evidenceIDs: [],
                reason: "Observer 发现 \(goalSignalCount) 条目标信号，值得深度跟进",
                generatedAt: now
            )
        ] : []
        let lastRunKey = "holo_agent_observer_tier2_last_run"
        let lastTier2RunAt = UserDefaults.standard.object(forKey: lastRunKey) as? Date
        let policy = HoloObserverTriggerPolicy()
        guard policy.shouldTriggerTier2(
            patterns: patterns, lastTier2RunAt: lastTier2RunAt, now: now, userRequested: false
        ) else { return }
        logger.info("Observer 触发 Tier2 深度分析（\(goalSignalCount) 条目标信号）")
        let question = "基于最近一次记忆观察（发现 \(goalSignalCount) 条目标信号），深度分析我的目标进度与潜在冲突。"
        Task { @MainActor in
            _ = await HoloAgentAnalysisService().runAnalysis(
                question: question,
                trigger: .observerTier2
            )
        }
        UserDefaults.standard.set(now, forKey: lastRunKey)
    }

    // MARK: - LLM Call

    private func callObserverLLM(userMessage: String) async throws -> String {
        let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
        let messages: [ChatMessageDTO] = [.user(userMessage)]
        return try await provider.chat(messages: messages, purpose: .memoryObserver)
    }

    // MARK: - Encoding

    private func encodePackageAsUserMessage(_ package: HoloObservationPackage) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(package),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Run Record

    private struct ObservationRunRecord: Codable {
        var runID: String
        var executedAt: Date
        var signalCount: Int
        var newCount: Int
        var hitCount: Int
        var expiredCount: Int
        var rejectedCount: Int
    }

    private func saveRunRecord(
        runID: String,
        signalCount: Int,
        result: ApplyResult,
        rejectedCount: Int
    ) {
        let record = ObservationRunRecord(
            runID: runID,
            executedAt: Date(),
            signalCount: signalCount,
            newCount: result.newCount,
            hitCount: result.hitCount,
            expiredCount: result.expiredCount,
            rejectedCount: rejectedCount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let json = String(data: data, encoding: .utf8) else { return }

        logger.info("Run record: \(json)")
    }
}
#endif
