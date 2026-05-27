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
}
