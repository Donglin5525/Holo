//
//  LightweightOnboardingSettingsTests.swift
//  HoloTests
//
//  轻量新人引导 V1 展示判断逻辑测试（对应方案 16.1）。
//

import XCTest
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
