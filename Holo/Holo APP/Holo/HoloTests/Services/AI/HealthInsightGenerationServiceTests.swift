//
//  HealthInsightGenerationServiceTests.swift
//  HoloTests
//
//  健康洞察生成服务编排测试：成功 / 数据不足 / 失败回退。
//

import XCTest
@testable import Holo

@MainActor
final class HealthInsightGenerationServiceTests: XCTestCase {

    func testGenerateReturnsFreshSnapshotOnSuccess() async throws {
        let provider = MockHealthInsightProvider()
        provider.response = #"{"coreInsight":{"id":"c","domain":"mixed","title":"恢复不足","summary":"摘要","confidence":0.7,"evidenceIds":["health-sleep-20260622"]}}"#
        provider.version = 1

        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: StubHealthDataSource()),
            provider: provider
        )
        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .fresh)
        XCTAssertNotNil(outcome.snapshot.coreInsight)
        XCTAssertEqual(outcome.promptVersion, 1)
        XCTAssertFalse(outcome.contextHashInput.isEmpty)
    }

    func testGenerateReturnsInsufficientWhenNoSleepData() async {
        let provider = MockHealthInsightProvider()
        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: EmptyHealthDataSource()),
            provider: provider
        )

        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .insufficientData)
        XCTAssertNil(outcome.snapshot.coreInsight)
        XCTAssertFalse(provider.wasCalled, "数据不足时不应调用 provider")
    }

    func testGenerateReturnsFallbackOnProviderError() async {
        let provider = MockHealthInsightProvider()
        provider.shouldThrow = true

        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: StubHealthDataSource()),
            provider: provider
        )

        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .fallback)
        // fallback 提供本地规则 core（方案 5.3），lifestyleLoops 为空（不展示伪跨模块）
        XCTAssertNotNil(outcome.snapshot.coreInsight)
        XCTAssertTrue(outcome.snapshot.lifestyleLoops.isEmpty)
        XCTAssertNotNil(outcome.snapshot.fallbackReason)
    }
}

// MARK: - Mock Provider

@MainActor
final class MockHealthInsightProvider: AIProvider {
    var lastCallLog: LLMCallLog?

    var response: String = "{}"
    var version: Int? = nil
    var shouldThrow = false
    private(set) var wasCalled = false

    func generateHealthInsight(contextJSON: String) async throws -> HealthInsightGenerationResult {
        wasCalled = true
        if shouldThrow {
            throw APIError.serverError("mock 生成失败")
        }
        return HealthInsightGenerationResult(rawResponse: response, promptVersion: version)
    }

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        throw APIError.serverError("not implemented")
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        throw APIError.serverError("not implemented")
    }

    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: APIError.serverError("not implemented"))
        }
    }
}

// MARK: - Stub DataSources

/// 提供一天低睡眠数据（isDataSufficient=true）。
private struct StubHealthDataSource: HealthInsightDataSource {
    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] {
        [DailyHealthData(date: start, value: 5.5)]
    }
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] { [] }
}

/// 无任何健康数据（isDataSufficient=false）。
private struct EmptyHealthDataSource: HealthInsightDataSource {
    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] { [] }
}
