//
//  LightweightOnboardingSettingsTests.swift
//  HoloTests
//
//  轻量新人引导 V1 展示判断逻辑测试（对应方案 16.1）。
//

import XCTest
import SwiftUI
@testable import Holo

final class LightweightOnboardingSettingsTests: XCTestCase {

    /// 构造每次用完即清的隔离 UserDefaults suite。
    private func makeSuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNewUserPresentsOnboarding() {
        let defaults = makeSuite("LWOnboardingNewUser")
        XCTAssertTrue(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: false
        ))
    }

    func testCompletedKeyHidesOnboarding() {
        let defaults = makeSuite("LWOnboardingCompleted")
        LightweightOnboardingSettings.markCompleted(defaults: defaults)
        XCTAssertFalse(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: false
        ))
    }

    func testLegacyUserNameOnboardingMigratesAndHides() {
        let defaults = makeSuite("LWOnboardingLegacy")
        // 模拟老用户：旧昵称 onboarding 已完成，新 key 尚未写。
        UserDisplayNameSettings(userDefaults: defaults).markOnboardingCompleted()
        XCTAssertFalse(defaults.bool(forKey: LightweightOnboardingSettings.completedKey))

        XCTAssertFalse(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: false
        ))
        // 迁移副作用：新 completed key 已写入，下次启动不再展示。
        XCTAssertTrue(defaults.bool(forKey: LightweightOnboardingSettings.completedKey))
    }

    func testDeepLinkPendingHidesWithoutWritingCompleted() {
        let defaults = makeSuite("LWOnboardingDeepLink")
        XCTAssertFalse(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: true,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: false
        ))
        // Deep Link 延后时不写 completed key，避免误把新用户标记为已完成。
        XCTAssertFalse(defaults.bool(forKey: LightweightOnboardingSettings.completedKey))
    }

    func testScreenshotModeSkipsEvenForNewUser() {
        let defaults = makeSuite("LWOnboardingScreenshot")
        // 同一新用户，截图模式关闭时展示。
        XCTAssertTrue(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: false
        ))
        // 截图模式最高优先级跳过。
        XCTAssertFalse(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: true,
            simulatorValidationActive: false
        ))
    }

    func testSimulatorValidationModeSkips() {
        let defaults = makeSuite("LWOnboardingSimulatorValidation")
        XCTAssertFalse(LightweightOnboardingSettings.shouldPresent(
            deepLinkPending: false,
            defaults: defaults,
            screenshotModeActive: false,
            simulatorValidationActive: true
        ))
    }
}

// MARK: - 首页三步导览说明卡定位规则（CoachMarkLayout）

/// iPhone 17 Pro 逻辑尺寸 402×874。
/// 对应真实三步：五角形区（大洞）/ 中央看板（中洞）/ 底部导航（矮洞需外扩含凸起）。
final class CoachMarkLayoutTests: XCTestCase {

    private let screenSize = CGSize(width: 402, height: 874)

    func testEstimatedCardHeightGrowsWithMessageLength() {
        let short = CoachMarkLayout.estimatedCardHeight(message: "短文案", cardWidth: 320)
        let long = CoachMarkLayout.estimatedCardHeight(
            message: String(repeating: "字", count: 120),
            cardWidth: 320
        )
        XCTAssertGreaterThan(long, short)
        // 120 字在 280pt 内容宽（每行 17 字）约 8 行，高度应超过 250
        XCTAssertGreaterThan(long, 250)
    }

    /// 第 2 步：中央看板洞，下方空间充足 → 卡片贴洞下方
    func testKanbanStepPutsCardBelow() {
        let hole = CGRect(x: 96, y: 170, width: 210, height: 480)
        let estimated = CoachMarkLayout.estimatedCardHeight(message: "点开看今天的任务、习惯和健康全貌，Holo 每天在这里帮你收个尾。", cardWidth: 320)
        XCTAssertEqual(
            CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: estimated),
            .top
        )
    }

    /// 第 3 步：底部导航洞（padding 40 外扩后 minY≈766），下方只有几十点 → 卡片必须放到洞上方
    func testBottomNavStepPutsCardAbove() {
        let hole = CGRect(x: -30, y: 766, width: 462, height: 148)
        let estimated = CoachMarkLayout.estimatedCardHeight(
            message: "不用想“该去哪记”——直接告诉 Holo 一件事，比如“午饭花了 35 元”，它会帮你记好。右边是记忆长廊，你的记录会自动汇成那里。",
            cardWidth: 320
        )
        XCTAssertEqual(
            CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: estimated),
            .bottom
        )
    }

    /// 第 1 步：五角形大洞（minY≈240 / maxY≈655），短文案下方放得下 → 贴下方
    func testFeatureButtonsStepPutsCardBelow() {
        let hole = CGRect(x: 12, y: 240, width: 378, height: 415)
        let estimated = CoachMarkLayout.estimatedCardHeight(
            message: "任务、财务、习惯、健康、想法，点开就能记录。长按图标还可以拖动，把最常用的放到顺手的位置。",
            cardWidth: 320
        )
        XCTAssertEqual(
            CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: estimated),
            .top
        )
    }

    /// 兜底：洞居中且巨大，上下都放不下 → 选下方（压 home indicator 好过压状态栏）
    func testGiantHoleFallsBackToBelow() {
        let hole = CGRect(x: 0, y: 180, width: 402, height: 520)
        XCTAssertEqual(
            CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: 260),
            .top
        )
    }

    /// 上方空间不足以容纳卡片时，应选下方兜底而不是让卡片侵入状态栏
    func testAbovePlacementRespectsTopSafeInset() {
        let hole = CGRect(x: 0, y: 300, width: 402, height: 100)
        // 洞上方空间 300-16-60=224 < 234，放不下 → 兜底选下方
        XCTAssertEqual(
            CoachMarkLayout.cardAlignment(hole: hole, screenSize: screenSize, estimatedHeight: 234),
            .top
        )
    }
}
