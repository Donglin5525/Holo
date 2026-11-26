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
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色模式")
        case .dark: return String(localized: "深色模式")
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
        withAnimation(HoloAnimation.smooth) {
            currentSetting = setting
        }

        HapticManager.light()
    }
}

// MARK: - 首页视觉模板（2026-11-24 允许用户自由切换，不一刀切）

/// 首页视觉模板选项
/// - classic: 经典光球（默认，完整保留既有品牌球体、五角形白卡入口与浮动底栏）
/// - sundial: 纸本星象 · 日晷时间针（方案 ②：极细精密刻度盘 + 实时日晷指针 + 线描五入口 + 刊脚底栏）
/// - moonPhase: 盈亏月相 · 晨昏切面（方案 ④：随今日进度柔和盈满的立体月相盘 + 星轨微光 + 刊脚底栏）
enum HomeTemplateStyle: String, CaseIterable, Identifiable {
    case classic = "classic"
    case sundial = "sundial"
    case moonPhase = "moonPhase"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return String(localized: "经典光球")
        case .sundial: return String(localized: "纸本星象 · 日晷")
        case .moonPhase: return String(localized: "盈亏月相 · 晨昏")
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return String(localized: "温暖橙色呼吸光球与三环轨道")
        case .sundial: return String(localized: "精密刻度表盘，指针随当下时刻缓缓转动")
        case .moonPhase: return String(localized: "立体月相随今日推进盈满，配柔和星轨光晕")
        }
    }

    /// 是否采用极简刊物系视觉（无白方块入口 + 墨线刊脚底栏 + 衬线问候）
    var isEditorial: Bool {
        self != .classic
    }
}

/// 首页视觉模板管理器（持久化至 UserDefaults）
final class HomeTemplateManager: ObservableObject {

    static let shared = HomeTemplateManager()

    private let storageKey = "holoHomeTemplateStyle"

    @Published var currentStyle: HomeTemplateStyle {
        didSet {
            UserDefaults.standard.set(currentStyle.rawValue, forKey: storageKey)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let style = HomeTemplateStyle(rawValue: raw) {
            currentStyle = style
        } else {
            currentStyle = .classic
        }
    }

    func updateStyle(_ style: HomeTemplateStyle) {
        guard currentStyle != style else { return }
        withAnimation(HoloAnimation.smooth) {
            currentStyle = style
        }
        HapticManager.light()
    }
}
