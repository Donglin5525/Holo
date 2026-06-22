import XCTest
@testable import Holo

/// 验证 `MemoryGalleryViewModel.constellationHealthSummary(for:)` 的口语化文案生成。
///
/// 星图健康卡片原本硬编码「接入中」占位，这里验证接入真实 HealthKit 数据后，
/// 周期日均睡眠/步数能转成口语化摘要（适当用数字辅助），并复用 AI 洞察侧的
/// 健康信号阈值（睡眠偏少 < 6h、步数偏低 < 3000）。
final class MemoryGalleryConstellationHealthTests: XCTestCase {

    // MARK: - 正常态：睡眠步数都够

    func testNormalSleepAndSteps() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: 7.2, averageSteps: 8521, periodLabel: "本周")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("7.2"), "应含睡眠数字")
        XCTAssertTrue(s.contains("8521"), "应含步数数字")
        XCTAssertFalse(s.contains("偏少"), "睡眠充足不应出现偏少")
        XCTAssertFalse(s.contains("动得不多"), "步数充足不应出现动得不多")
    }

    // MARK: - 睡眠偏少

    func testSleepShort() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: 5.5, averageSteps: 8521, periodLabel: "本周")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("睡得偏少"), "睡眠 <6h 应提示偏少")
        XCTAssertTrue(s.contains("5.5"))
    }

    // MARK: - 步数偏低

    func testStepsLow() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: 7.2, averageSteps: 2800, periodLabel: "本周")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("动得不多"), "步数 <3000 应提示动得不多")
        XCTAssertTrue(s.contains("2800"))
    }

    // MARK: - 只有睡眠

    func testSleepOnly() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: 7.0, averageSteps: nil, periodLabel: "本周")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("7.0"))
        XCTAssertFalse(s.contains("步"), "无步数数据不应出现步数句")
    }

    // MARK: - 只有步数

    func testStepsOnly() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: nil, averageSteps: 8521, periodLabel: "本周")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("8521"))
        XCTAssertFalse(s.contains("小时"), "无睡眠数据不应出现睡眠句")
    }

    // MARK: - 完全无数据

    func testNoDataReturnsNil() {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: nil, averageSteps: nil, periodLabel: "本周")
        )
        XCTAssertNil(summary, "睡眠步数都读不到时应返回 nil，由调用方走「已授权无数据」占位")
    }

    // MARK: - 周期词随 periodLabel 变化

    func testPeriodLabelUsedInSummary() throws {
        let summary = MemoryGalleryViewModel.constellationHealthSummary(for:
            .init(averageSleepHours: 5.5, averageSteps: nil, periodLabel: "本月")
        )
        let s = try XCTUnwrap(summary)
        XCTAssertTrue(s.contains("本月"), "应使用传入的周期词")
    }
}
