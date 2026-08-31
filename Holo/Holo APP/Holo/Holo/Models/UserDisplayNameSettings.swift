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
    /// 昵称从未设置时的展示占位（用于昵称行等独立展示位；句子拼接走 greetingText，不用它）
    static let unsetDisplayNamePlaceholder = "未设置"
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

    /// 用户是否真正设置过昵称（非空且不是兜底代词）
    static func isDisplayNameSet(_ rawName: String?) -> Bool {
        guard let name = normalizedDisplayName(rawName) else { return false }
        return name != fallbackDisplayName
    }

    /// 统一问候语组装：时段问候 + 称呼。
    /// 没设置过昵称时省略称呼（「下午好」而不是「下午好，你」），首页与看板页共用。
    static func greetingText(hour: Int, rawName: String?) -> String {
        let hourPart: String
        switch hour {
        case 0..<6: hourPart = "夜深了"
        case 6..<12: hourPart = "早上好"
        case 12..<18: hourPart = "下午好"
        default: hourPart = "晚上好"
        }
        guard let name = normalizedDisplayName(rawName), name != fallbackDisplayName else {
            return hourPart
        }
        return "\(hourPart)，\(name)"
    }

    /// 昵称独立展示位的取值：未设置时返回占位文案，避免把兜底代词「你」当成昵称展示
    static func displayOrPlaceholder(_ rawName: String?) -> String {
        guard let name = normalizedDisplayName(rawName), name != fallbackDisplayName else {
            return unsetDisplayNamePlaceholder
        }
        return name
    }
}
