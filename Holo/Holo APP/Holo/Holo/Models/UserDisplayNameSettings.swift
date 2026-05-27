//
//  UserDisplayNameSettings.swift
//  Holo
//
//  用户昵称本地持久化设置
//

import Foundation

struct UserDisplayNameSettings {

    static let displayNameKey = "userName"
    static let onboardingKey = "hasCompletedUserNameOnboarding"
    static let fallbackDisplayName = "你"
    static let standard = UserDisplayNameSettings()

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var displayName: String {
        Self.normalizedDisplayName(userDefaults.string(forKey: Self.displayNameKey))
            ?? Self.fallbackDisplayName
    }

    var hasCompletedOnboarding: Bool {
        userDefaults.bool(forKey: Self.onboardingKey)
    }

    @discardableResult
    func saveDisplayName(_ rawName: String) -> String {
        guard let displayName = Self.normalizedDisplayName(rawName) else {
            return self.displayName
        }

        userDefaults.set(displayName, forKey: Self.displayNameKey)
        userDefaults.set(true, forKey: Self.onboardingKey)
        return displayName
    }

    func markOnboardingCompleted() {
        userDefaults.set(true, forKey: Self.onboardingKey)
    }

    static func normalizedDisplayName(_ rawName: String?) -> String? {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}
