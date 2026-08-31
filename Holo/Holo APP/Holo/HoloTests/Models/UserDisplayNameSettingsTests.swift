//
//  UserDisplayNameSettingsTests.swift
//  HoloTests
//
//  用户昵称持久化规则测试
//

import XCTest
@testable import Holo

final class UserDisplayNameSettingsTests: XCTestCase {

    func testSaveDisplayNameTrimsWhitespaceAndPersists() {
        let suiteName = "UserDisplayNameSettingsTrimTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = UserDisplayNameSettings(userDefaults: defaults)

        let savedName = settings.saveDisplayName("  林夕  ")

        XCTAssertEqual(savedName, "林夕")
        XCTAssertEqual(settings.displayName, "林夕")
        XCTAssertTrue(settings.hasCompletedOnboarding)
    }

    func testBlankDisplayNameDoesNotOverwriteExistingName() {
        let suiteName = "UserDisplayNameSettingsBlankTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = UserDisplayNameSettings(userDefaults: defaults)
        settings.saveDisplayName("阿北")

        let savedName = settings.saveDisplayName("   ")

        XCTAssertEqual(savedName, "阿北")
        XCTAssertEqual(settings.displayName, "阿北")
    }

    // MARK: - 问候语组装

    func testGreetingWithSetNameAppendsSalutation() {
        XCTAssertEqual(
            UserDisplayNameSettings.greetingText(hour: 15, rawName: "林夕"),
            "下午好，林夕"
        )
    }

    func testGreetingWithoutNameOmitsSalutation() {
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 15, rawName: nil), "下午好")
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 15, rawName: "   "), "下午好")
    }

    /// @AppStorage 的默认值是兜底代词「你」，问候语不能把它当真名字拼出去
    func testGreetingWithFallbackPronounOmitsSalutation() {
        XCTAssertEqual(
            UserDisplayNameSettings.greetingText(hour: 9, rawName: UserDisplayNameSettings.fallbackDisplayName),
            "早上好"
        )
    }

    func testGreetingCoversAllDayParts() {
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 2, rawName: "林夕"), "夜深了，林夕")
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 8, rawName: "林夕"), "早上好，林夕")
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 14, rawName: "林夕"), "下午好，林夕")
        XCTAssertEqual(UserDisplayNameSettings.greetingText(hour: 21, rawName: "林夕"), "晚上好，林夕")
    }

    // MARK: - 昵称展示占位

    func testDisplayOrPlaceholderReturnsPlaceholderWhenUnset() {
        XCTAssertEqual(UserDisplayNameSettings.displayOrPlaceholder(nil), "未设置")
        XCTAssertEqual(UserDisplayNameSettings.displayOrPlaceholder("  "), "未设置")
        XCTAssertEqual(
            UserDisplayNameSettings.displayOrPlaceholder(UserDisplayNameSettings.fallbackDisplayName),
            "未设置"
        )
    }

    func testDisplayOrPlaceholderReturnsNameWhenSet() {
        XCTAssertEqual(UserDisplayNameSettings.displayOrPlaceholder("  林夕  "), "林夕")
    }
}
