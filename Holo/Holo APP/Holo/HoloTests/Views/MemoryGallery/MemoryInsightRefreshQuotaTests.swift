import XCTest
@testable import Holo

/// 验证 `MemoryInsightRefreshQuota` 的每日配额计数与跨天重置。
///
/// 星图「更新」与 AI 回放「重新生成」共享同一每日配额（默认 2 次/天，按自然日重置）。
/// 用独立 UserDefaults suite 隔离，避免污染全局 .standard。
final class MemoryInsightRefreshQuotaTests: XCTestCase {

    private var defaults: UserDefaults!
    private var quota: MemoryInsightRefreshQuota!

    override func setUp() {
        super.setUp()
        // 每个测试用唯一 suite，互不干扰
        let suite = "MemoryInsightRefreshQuotaTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        quota = MemoryInsightRefreshQuota(userDefaults: defaults)
    }

    override func tearDown() {
        quota = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 初始态：全新 suite 应为满配额

    func testInitialQuotaFull() {
        XCTAssertTrue(quota.canRefresh(), "全新 suite 初始应可刷新")
        XCTAssertEqual(quota.remainingToday, MemoryInsightRefreshQuota.maxPerDay)
        XCTAssertEqual(quota.usedToday, 0)
    }

    // MARK: - 消耗到上限

    func testConsumeUntilExhausted() {
        XCTAssertTrue(quota.consume(), "第 1 次应成功")
        XCTAssertEqual(quota.remainingToday, 1)

        XCTAssertTrue(quota.consume(), "第 2 次应成功")
        XCTAssertEqual(quota.remainingToday, 0)

        XCTAssertFalse(quota.canRefresh(), "用完后应不可刷新")
    }

    // MARK: - 超限不再消耗（计数不涨）

    func testConsumeBeyondLimitReturnsFalse() {
        _ = quota.consume()
        _ = quota.consume()
        XCTAssertEqual(quota.usedToday, MemoryInsightRefreshQuota.maxPerDay)

        XCTAssertFalse(quota.consume(), "第 3 次应失败")
        XCTAssertEqual(
            quota.usedToday,
            MemoryInsightRefreshQuota.maxPerDay,
            "超限不应再涨计数"
        )
    }

    // MARK: - 跨天重置：lastDay 非今天时计数归零

    func testResetsAcrossDay() {
        // 先把今天配额用完
        _ = quota.consume()
        _ = quota.consume()
        XCTAssertEqual(quota.remainingToday, 0)

        // 模拟「昨天」的持久化状态（key 与实现保持一致）
        let yesterday = Date().addingDays(-1)
        defaults.set(yesterday.timeIntervalSince1970, forKey: "com.holo.insight.refresh.lastDay")
        defaults.set(2, forKey: "com.holo.insight.refresh.count")

        // 跨天后应视为未用
        XCTAssertEqual(quota.usedToday, 0, "跨天应重置为 0")
        XCTAssertTrue(quota.canRefresh())
        XCTAssertEqual(quota.remainingToday, MemoryInsightRefreshQuota.maxPerDay)

        // 跨天后第一次 consume 应从 1 开始
        XCTAssertTrue(quota.consume())
        XCTAssertEqual(quota.usedToday, 1)
    }

    // MARK: - 同天 consume 后持久化生效（重读实例可见）

    func testPersistenceSharedAcrossInstances() {
        _ = quota.consume()

        // 用同一 defaults 新建实例，应读到已用 1 次
        let reread = MemoryInsightRefreshQuota(userDefaults: defaults)
        XCTAssertEqual(reread.usedToday, 1, "配额写入 UserDefaults 后，新实例应可见")
        XCTAssertEqual(reread.remainingToday, MemoryInsightRefreshQuota.maxPerDay - 1)
    }
}
