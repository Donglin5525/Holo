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
    /// 本次安装里是否主动设置过昵称（UserDefaults 随卸载清空，重装后自然复位）
    /// 用于云端昵称采纳的冲突判定：主动设置过 → 本地意图优先，不被云端覆盖
    static let displayNameSetThisInstallKey = "displayNameSetThisInstall"
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

    var hasSetDisplayNameThisInstall: Bool {
        userDefaults.bool(forKey: Self.displayNameSetThisInstallKey)
    }

    @discardableResult
    func saveDisplayName(_ rawName: String) -> String {
        guard let displayName = Self.normalizedDisplayName(rawName) else {
            return self.displayName
        }

        userDefaults.set(displayName, forKey: Self.displayNameKey)
        userDefaults.set(true, forKey: Self.displayNameSetThisInstallKey)
        userDefaults.set(true, forKey: Self.onboardingKey)
        return displayName
    }

    /// 采纳云端恢复的名字：只更新本地显示，
    /// 不算本次安装的主动设置（不影响后续冲突判定），不动 onboarding 标记
    func adoptCloudDisplayName(_ rawName: String) {
        guard let displayName = Self.normalizedDisplayName(rawName) else { return }
        userDefaults.set(displayName, forKey: Self.displayNameKey)
    }

    func markOnboardingCompleted() {
        userDefaults.set(true, forKey: Self.onboardingKey)
    }

    static func normalizedDisplayName(_ rawName: String?) -> String? {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}
