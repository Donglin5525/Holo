//
//  AppLockSettings.swift
//  Holo
//
//  应用锁配置存储
//  开关状态与锁定宽限档位，默认关闭 + 5 分钟宽限
//  惯例参照 MemoryInsightScheduleSettings（@Published didSet 持久化）
//

import Foundation
import Combine

@MainActor
final class AppLockSettings: ObservableObject {

    static let shared = AppLockSettings()

    /// 测试注入隔离 UserDefaults 用；生产统一走 shared
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        self.graceStyle = GraceStyle(rawValue: defaults.string(forKey: Keys.graceStyle) ?? "") ?? .fiveMinutes
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let isEnabled = "appLock_isEnabled"
        static let graceStyle = "appLock_graceStyle"
    }

    /// 回前台重新验证的宽限档位
    enum GraceStyle: String, CaseIterable {
        case immediate
        case oneMinute
        case fiveMinutes

        var seconds: TimeInterval {
            switch self {
            case .immediate: return 0
            case .oneMinute: return 60
            case .fiveMinutes: return 300
            }
        }

        var displayName: String {
            switch self {
            case .immediate: return "立即锁定"
            case .oneMinute: return "1 分钟内免验证"
            case .fiveMinutes: return "5 分钟内免验证"
            }
        }

        var subtitle: String {
            switch self {
            case .immediate: return "切出 App 后回来需立即验证"
            case .oneMinute: return "离开不超过 1 分钟回来可免验证"
            case .fiveMinutes: return "离开不超过 5 分钟回来可免验证"
            }
        }
    }

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var graceStyle: GraceStyle {
        didSet { defaults.set(graceStyle.rawValue, forKey: Keys.graceStyle) }
    }
}
