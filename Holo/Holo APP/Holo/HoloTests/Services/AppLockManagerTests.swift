//
//  AppLockManagerTests.swift
//  HoloTests
//
//  应用锁单测：宽限判定纯函数 + 配置存储
//  时间一律用固定时间戳构造（守则：禁 Date() + 写死日历日期，跨月必炸）
//

import XCTest
@testable import Holo

final class AppLockManagerTests: XCTestCase {

    // MARK: - 宽限判定（shouldLock 纯函数）

    /// 固定基准时刻（Unix 时间戳，无时区/日历依赖）
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func after(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    func testImmediateStyleLocksImmediately() {
        XCTAssertTrue(AppLockManager.shouldLock(lastBackgroundedAt: base, now: after(1), grace: 0))
    }

    func testWithinGraceWindowDoesNotLock() {
        XCTAssertFalse(AppLockManager.shouldLock(lastBackgroundedAt: base, now: after(59), grace: 60))
        XCTAssertFalse(AppLockManager.shouldLock(lastBackgroundedAt: base, now: after(299), grace: 300))
    }

    func testBeyondGraceWindowLocks() {
        XCTAssertTrue(AppLockManager.shouldLock(lastBackgroundedAt: base, now: after(60), grace: 60))
        XCTAssertTrue(AppLockManager.shouldLock(lastBackgroundedAt: base, now: after(300), grace: 300))
    }

    func testMissingBackgroundTimestampLocksConservatively() {
        // 进程被系统直接挂起等异常路径导致时间戳缺失：保守锁定
        XCTAssertTrue(AppLockManager.shouldLock(lastBackgroundedAt: nil, now: after(0), grace: 300))
    }

    // MARK: - 配置存储（AppLockSettings）

    @MainActor
    func testSettingsDefaults() async throws {
        let suiteName = "AppLockManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppLockSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.graceStyle, .fiveMinutes)
        XCTAssertEqual(settings.graceStyle.seconds, 300)
    }

    @MainActor
    func testSettingsPersistenceRoundTrip() async throws {
        let suiteName = "AppLockManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppLockSettings(defaults: defaults)
        settings.isEnabled = true
        settings.graceStyle = .oneMinute

        let reloaded = AppLockSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.graceStyle, .oneMinute)
    }

    @MainActor
    func testSettingsInvalidStoredGraceFallsBackToDefault() async throws {
        let suiteName = "AppLockManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 存量脏数据（手工改库/旧版本残留）回落默认 5 分钟档
        defaults.set("bogus-value", forKey: "appLock_graceStyle")
        XCTAssertEqual(AppLockSettings(defaults: defaults).graceStyle, .fiveMinutes)
    }
}
