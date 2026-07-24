//
//  LightweightOnboardingSettings.swift
//  Holo
//
//  轻量新人引导 V1 本地状态
//  仅维护一个 UserDefaults Bool 与新老用户迁移判断，不引入状态机/Core Data/CloudKit。
//

import Foundation

/// 轻量 onboarding 完成时用户做出的选择。
/// 仅用于决定是否授予 AI 数据处理授权，以及是否保存昵称草稿。
enum OnboardingCompletionChoice {
    /// 第四页点击「同意并开始使用」：授予 AI 数据处理授权。
    case grantedAIConsent
    /// 第四页点击「暂不授权，先进入 Holo」：保持现有 consent 状态。
    case skippedAIConsent
    /// 任一页点击「跳过」：不保存昵称草稿，不授予授权。
    case skippedOnboarding
}

/// 轻量新人引导 V1 状态封装。
///
/// 只增加一个 UserDefaults Bool（`completedKey`）。AI 入口提示使用 `HomeView`
/// 当前会话内的 `@State` 控制，不在此处持久化——它只由本次 onboarding 完成回调触发。
enum LightweightOnboardingSettings {

    /// 是否已完成轻量 onboarding（含跳过）。
    static let completedKey = "holo_onboarding_lightweight_v1_completed"

    /// 当前是否已完成轻量 onboarding。
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// 标记轻量 onboarding 已完成。
    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// 判断本次进入首页是否需要展示轻量 onboarding。
    ///
    /// 按方案 10.3 节优先级判定，并在命中「旧昵称 onboarding 已完成」时顺带写入新 key
    /// （老用户迁移），避免下次启动重复判定。
    ///
    /// - Parameters:
    ///   - deepLinkPending: 本次进入首页前是否存在待处理 Deep Link。
    ///   - defaults: 注入的 UserDefaults，便于测试。
    ///   - screenshotModeActive: DEBUG 截图模式是否激活（最高优先级跳过）。
    ///   - simulatorValidationActive: 模拟器验收模式是否激活（最高优先级跳过）。
    /// - Returns: 是否需要展示 onboarding。返回 `false` 时可能是已完成、已迁移、
    ///   DEBUG 模式或因 Deep Link 延后。
    static func shouldPresent(
        deepLinkPending: Bool,
        defaults: UserDefaults = .standard,
        screenshotModeActive: Bool = defaultScreenshotModeActive,
        simulatorValidationActive: Bool = defaultSimulatorValidationActive
    ) -> Bool {
        // 1. DEBUG 截图或模拟器验收模式：最高优先级显式跳过。
        if screenshotModeActive || simulatorValidationActive {
            return false
        }
        // 2. 已完成轻量 onboarding：不展示。
        if defaults.bool(forKey: completedKey) {
            return false
        }
        // 3. 旧昵称 onboarding 已完成：视为老用户，写入新 completed key 并跳过。
        if UserDisplayNameSettings(userDefaults: defaults).hasCompletedOnboarding {
            markCompleted(defaults: defaults)
            return false
        }
        // 4. 本次存在待处理 Deep Link：本次不展示，也不写 completed key。
        if deepLinkPending {
            return false
        }
        // 5. 其他情况：展示轻量 onboarding。
        return true
    }
}

// MARK: - DEBUG 验收模式默认值

extension LightweightOnboardingSettings {

    /// DEBUG 截图模式默认读取真实环境标志；Release 恒为 false。
    static var defaultScreenshotModeActive: Bool {
        #if DEBUG
        return HoloAppStoreScreenshotSeeder.isRequested
        #else
        return false
        #endif
    }

    /// 模拟器记忆验收模式默认读取真实环境标志；Release 恒为 false。
    static var defaultSimulatorValidationActive: Bool {
        #if DEBUG
        return HoloMemorySimulatorValidationEnvironment.current != nil
        #else
        return false
        #endif
    }
}
