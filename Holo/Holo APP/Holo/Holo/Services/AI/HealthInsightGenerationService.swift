//
//  HealthInsightGenerationService.swift
//  Holo
//
//  健康洞察生成编排服务（方案 3.1：含缓存编排）。
//  - generate(now:)：纯生成（context → provider → parser → verifier → snapshot），测试入口。
//  - load(now:)：面向 UI 的加载，含缓存优先、失败节流、按需刷新（方案 6.1/6.2）。
//

import Foundation

/// 一次生成的完整产物：snapshot + 缓存所需元信息。
struct HealthInsightGenerationOutcome: Sendable {
    var snapshot: GeneratedHealthInsightSnapshot
    var contextHashInput: String
    var promptVersion: Int?
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

    // MARK: - 面向 UI 的加载（缓存优先 + 节流 + 按需生成）

    /// 加载今日洞察：先返回缓存，按需调 API（方案 6.1/6.2）。
    func load(now: Date = Date()) async -> GeneratedHealthInsightSnapshot {
        let today = Calendar.current.startOfDay(for: now)
        let cached = cache.loadSnapshot(for: today)

        // 失败节流：30 分钟内不重试（P8：自动/手动共享）
        if cache.isThrottled(now: now) {
            return cached ?? fallbackBuilder.buildFallback(period: defaultPeriod(now: now), reason: nil, now: now)
        }

        let context = await contextBuilder.build()

        guard context.isDataSufficient else {
            return fallbackBuilder.buildInsufficientData(period: context.period, now: now)
        }

        // 已缓存且 contextHash 未变（promptVersion 变化也触发刷新，N4）→ 用缓存，不调 API
        if let cached, !cache.needsRefresh(for: today, contextHashInput: context.contextHashInput, currentPromptVersion: nil) {
            return cached
        }

        let outcome = await generate(now: now)
        switch outcome.snapshot.status {
        case .fresh:
            cache.save(outcome, for: today, now: now)
        case .fallback:
            cache.recordFailure(now: now)
        default:
            break
        }
        return outcome.snapshot
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
        } catch {
            return outcome(
                snapshot: fallbackBuilder.buildFallback(
                    period: context.period,
                    reason: "生成失败：\(error.localizedDescription)",
                    now: now
                ),
                contextHashInput: context.contextHashInput,
                promptVersion: nil
            )
        }
    }

    // MARK: - Helpers

    private func defaultPeriod(now: Date) -> HealthInsightPeriod {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return HealthInsightPeriod(start: start, end: end, days: 14)
    }

    private func outcome(
        snapshot: GeneratedHealthInsightSnapshot,
        contextHashInput: String,
        promptVersion: Int?
    ) -> HealthInsightGenerationOutcome {
        HealthInsightGenerationOutcome(snapshot: snapshot, contextHashInput: contextHashInput, promptVersion: promptVersion)
    }
}
