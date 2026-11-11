//
//  HealthInsightGenerationService.swift
//  Holo
//
//  健康洞察生成编排服务（方案 3.1：含缓存编排）。
//  - generate(now:)：纯生成（context → provider → parser → verifier → snapshot），测试入口。
//  - generateRespectingFreshness(now:ignoreFreshness:staleCacheAge:)：后台单飞行生成入口，
//    含新鲜度门控与「取消≠失败」分类（HealthInsightScheduler 调用）。
//  - displaySeedSnapshot(now:)：页面只读显示的种子快照（今日缓存 → 最近缓存 → 保底文案）。
//

import Foundation

/// 一次生成的完整产物：snapshot + 缓存所需元信息。
struct HealthInsightGenerationOutcome: Sendable {
    var snapshot: GeneratedHealthInsightSnapshot
    var contextHashInput: String
    var promptVersion: Int?
}

/// 后台按需生成的结果分类（供 HealthInsightScheduler 编排缓存与页面状态）。
enum HealthInsightBackgroundResult {
    /// 成功生成（core 校验失败时为本地规则 core 的 fresh 快照），可缓存。
    case generated(HealthInsightGenerationOutcome)
    /// 新鲜度规则或失败节流判定无需生成，未调模型。
    case skipped
    /// 数据不足，未调模型，附带诚实空态快照。
    case insufficientData(GeneratedHealthInsightSnapshot)
    /// 取消（后台租约到期等）：不记失败、不覆盖已有缓存与页面显示。
    case cancelled
    /// 真失败（网络/服务端/解析）：已记录 30 分钟失败节流，附带 fallback 快照。
    case failed(GeneratedHealthInsightSnapshot)
}

@MainActor
final class HealthInsightGenerationService {

    private let contextBuilder: HealthInsightContextBuilder
    private let provider: AIProvider
    private let parser: HealthInsightResponseParser
    private let verifier: HealthInsightVerifier
    private let fallbackBuilder: HealthInsightFallbackBuilder
    private let cache: HealthInsightCache

    init(
        contextBuilder: HealthInsightContextBuilder,
        provider: AIProvider,
        parser: HealthInsightResponseParser? = nil,
        verifier: HealthInsightVerifier? = nil,
        fallbackBuilder: HealthInsightFallbackBuilder? = nil,
        cache: HealthInsightCache? = nil
    ) {
        self.contextBuilder = contextBuilder
        self.provider = provider
        self.parser = parser ?? HealthInsightResponseParser()
        self.verifier = verifier ?? HealthInsightVerifier()
        self.fallbackBuilder = fallbackBuilder ?? HealthInsightFallbackBuilder()
        self.cache = cache ?? .shared
    }

    // MARK: - 后台单飞行生成（新鲜度门控 + 取消≠失败）

    /// 按需生成：数据不足不调模型；今日缓存 hash 未变、或 hash 变了但未到 staleness 年龄 → 跳过。
    /// 取消类错误（任务取消 / URL 请求取消）不记失败节流、不产出覆盖性快照；真失败保持 30 分钟节流。
    func generateRespectingFreshness(
        now: Date,
        ignoreFreshness: Bool,
        staleCacheAge: TimeInterval
    ) async -> HealthInsightBackgroundResult {
        let today = Calendar.current.startOfDay(for: now)

        // 失败节流：30 分钟内不重试（P8：自动/手动共享）
        if cache.isThrottled(now: now) {
            return .skipped
        }

        let context = await contextBuilder.build()

        guard context.isDataSufficient else {
            return .insufficientData(fallbackBuilder.buildInsufficientData(period: context.period, now: now))
        }

        if !ignoreFreshness {
            // 已缓存且 contextHash 未变（promptVersion 变化也触发刷新，N4）→ 不调 API
            if !cache.needsRefresh(for: today, contextHashInput: context.contextHashInput, currentPromptVersion: nil) {
                return .skipped
            }
            // hash 变了但缓存还新（< staleCacheAge）：白天步数等波动不触发一天内反复生成
            if let savedAt = cache.entrySavedAt(for: today), now.timeIntervalSince(savedAt) < staleCacheAge {
                return .skipped
            }
        }

        do {
            return .generated(try await generateOutcome(context: context, now: now))
        } catch {
            if Self.isCancellation(error) {
                return .cancelled
            }
            cache.recordFailure(now: now)
            return .failed(fallbackBuilder.buildFallback(
                period: context.period,
                reason: String(localized: "生成失败：\(error.localizedDescription)"),
                now: now
            ))
        }
    }

    /// 页面只读显示的种子快照：今日缓存 → 最近 7 天缓存 → 本地保底文案（不发起生成、不阻塞）。
    func displaySeedSnapshot(now: Date) -> GeneratedHealthInsightSnapshot {
        let today = Calendar.current.startOfDay(for: now)
        if let cached = cache.loadSnapshot(for: today) {
            return cached
        }
        if let latest = cache.loadLatestSnapshot(now: now) {
            return latest
        }
        return fallbackBuilder.buildFallback(period: defaultPeriod(now: now), reason: nil, now: now)
    }

    // MARK: - 纯生成（测试入口）

    func generate(now: Date = Date()) async -> HealthInsightGenerationOutcome {
        let context = await contextBuilder.build()

        guard context.isDataSufficient else {
            return outcome(
                snapshot: fallbackBuilder.buildInsufficientData(period: context.period, now: now),
                contextHashInput: context.contextHashInput,
                promptVersion: nil
            )
        }

        do {
            return try await generateOutcome(context: context, now: now)
        } catch {
            return outcome(
                snapshot: fallbackBuilder.buildFallback(
                    period: context.period,
                    reason: String(localized: "生成失败：\(error.localizedDescription)"),
                    now: now
                ),
                contextHashInput: context.contextHashInput,
                promptVersion: nil
            )
        }
    }

    // MARK: - Helpers

    /// provider → parser → verifier → fresh snapshot（generate 与后台生成共用管线）。
    private func generateOutcome(
        context: HealthInsightContextBuildResult,
        now: Date
    ) async throws -> HealthInsightGenerationOutcome {
        let result = try await provider.generateHealthInsight(contextJSON: context.contextJSON)
        let parsed = try parser.parse(result.rawResponse, legalEvidenceIds: context.legalEvidenceIds)
        let verified = verifier.verify(parsed, evidence: context.evidence)
        // core 校验失败时回退到本地规则 core（方案 5.2）；loops 用校验通过的
        let coreInsight = verified.coreInsight ?? fallbackBuilder.buildFallbackCore(now: now)
        let snapshot = GeneratedHealthInsightSnapshot(
            generatedAt: now,
            period: context.period,
            status: .fresh,
            coreInsight: coreInsight,
            lifestyleLoops: verified.lifestyleLoops,
            evidence: context.evidence,
            fallbackReason: nil
        )
        return outcome(snapshot: snapshot, contextHashInput: context.contextHashInput, promptVersion: result.promptVersion)
    }

    /// 取消类错误：任务取消 / URL 层取消 / API 封装取消（取消不是失败，不节流）。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let apiError = error as? APIError, case .cancelled = apiError { return true }
        return false
    }

    private func defaultPeriod(now: Date) -> HealthInsightPeriod {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let windowDays = HealthThresholds.insightWindowDays
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return HealthInsightPeriod(start: start, end: end, days: windowDays)
    }

    private func outcome(
        snapshot: GeneratedHealthInsightSnapshot,
        contextHashInput: String,
        promptVersion: Int?
    ) -> HealthInsightGenerationOutcome {
        HealthInsightGenerationOutcome(snapshot: snapshot, contextHashInput: contextHashInput, promptVersion: promptVersion)
    }
}
