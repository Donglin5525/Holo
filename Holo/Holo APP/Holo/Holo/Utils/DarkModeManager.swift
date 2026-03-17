//
//  DarkModeManager.swift
//  Holo
//
//  深色模式管理器
//  支持三种模式：跟随系统、浅色模式、深色模式
//

import SwiftUI
import Combine

// MARK: - 深色模式枚举

/// 深色模式设置选项
enum DarkModeSetting: String, CaseIterable {
    case system = "system"      // 跟随系统
    case light = "light"        // 浅色模式
    case dark = "dark"          // 深色模式

    /// 显示名称
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    /// 图标名称
    var iconName: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 转换为 ColorScheme
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil  // nil 表示使用系统设置
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 深色模式管理器

/// 深色模式管理器
/// 使用 UserDefaults 持久化用户设置
class DarkModeManager: ObservableObject {

    // MARK: - Singleton

    static let shared = DarkModeManager()

    // MARK: - Constants

    private let settingsKey = "darkModeSetting"

    // MARK: - Properties

    /// 当前设置（发布变化通知）
    @Published var currentSetting: DarkModeSetting {
        didSet {
            UserDefaults.standard.set(currentSetting.rawValue, forKey: settingsKey)
        }
    }

    /// 当前 ColorScheme（用于 .preferredColorScheme 修饰符）
    var colorScheme: ColorScheme? {
        currentSetting.colorScheme
    }

    // MARK: - Initialization

    private init() {
        // 从持久化存储恢复设置
        if let rawValue = UserDefaults.standard.string(forKey: settingsKey),
           let setting = DarkModeSetting(rawValue: rawValue) {
            currentSetting = setting
        } else {
            currentSetting = .system
        }
    }

    // MARK: - Methods

    /// 更新深色模式设置
    func updateSetting(_ setting: DarkModeSetting) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentSetting = setting
        }

        // 触发 Haptic 反馈
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()
    }
}
