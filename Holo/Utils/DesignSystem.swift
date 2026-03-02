//
//  DesignSystem.swift
//  Holo
//
//  设计系统 - 包含颜色、字体、间距等设计规范
//

import SwiftUI

// MARK: - 颜色系统

/// Holo 应用颜色系统
/// 基于 Figma 设计稿定义的品牌色和功能性颜色
extension Color {
    
    // MARK: - 品牌主色 (Primary Orange)
    /// 主色调 - 用于强调元素和主要交互
    static let holoPrimary = Color(red: 244/255, green: 109/255, blue: 56/255)  // #F46D38
    static let holoPrimaryLight = Color(red: 254/255, green: 215/255, blue: 170/255)  // #FED7AA
    static let holoPrimaryDark = Color(red: 234/255, green: 88/255, blue: 12/255)  // #EA580C
    
    // MARK: - 背景色
    /// 主背景色 - 米白色调
    static let holoBackground = Color(red: 253/255, green: 251/255, blue: 247/255)  // #FDFBF7
    
    // MARK: - 文字颜色
    /// 主文字颜色 - 深灰色
    static let holoTextPrimary = Color(red: 51/255, green: 51/255, blue: 51/255)  // #333333
    /// 次要文字颜色 - 中灰色
    static let holoTextSecondary = Color(red: 142/255, green: 142/255, blue: 147/255)  // #8E8E93
    
    // MARK: - 功能性颜色
    /// 成功状态 - 绿色圆点指示
    static let holoSuccess = Color(red: 34/255, green: 197/255, blue: 94/255)  // #22C55E
    /// 信息提示 - 蓝色
    static let holoInfo = Color(red: 96/255, green: 165/255, blue: 250/255)  // #60A5FA
    /// 紫色装饰
    static let holoPurple = Color(red: 192/255, green: 132/255, blue: 252/255)  // #C084FC
    
    // MARK: - 卡片/按钮背景
    /// 毛玻璃背景色
    static let holoGlassBackground = Color.white.opacity(0.7)
    /// 边框颜色
    static let holoBorder = Color.white.opacity(0.2)
}

// MARK: - 字体系统

/// Holo 应用字体系统
/// 统一管理字体大小和样式
extension Font {
    /// 大标题 - 28pt Bold，用于主要标题
    static let holoTitle = Font.system(size: 28, weight: Font.Weight.bold)
    
    /// 页面标题 - 20pt Semibold，用于页面头部
    static let holoHeading = Font.system(size: 20, weight: Font.Weight.semibold)
    
    /// 正文 - 16pt Medium，用于主要内容
    static let holoBody = Font.system(size: 16, weight: Font.Weight.medium)
    
    /// 辅助文字 - 14pt Regular，用于说明文字
    static let holoCaption = Font.system(size: 14, weight: Font.Weight.regular)
    
    /// 小标签 - 12pt Medium，用于按钮标签
    static let holoLabel = Font.system(size: 12, weight: Font.Weight.medium)
    
    /// 超小标签 - 10pt Medium，用于底部导航标签
    static let holoTinyLabel = Font.system(size: 10, weight: Font.Weight.medium)
}

// MARK: - 间距系统

/// Holo 应用间距常量
/// 保持界面的一致性和呼吸感
struct HoloSpacing {
    /// 超小间距 - 4pt
    static let xs: CGFloat = 4
    /// 小间距 - 8pt
    static let sm: CGFloat = 8
    /// 中等间距 - 16pt
    static let md: CGFloat = 16
    /// 大间距 - 24pt
    static let lg: CGFloat = 24
    /// 超大间距 - 32pt
    static let xl: CGFloat = 32
    /// 巨大间距 - 48pt
    static let xxl: CGFloat = 48
}

// MARK: - 圆角系统

/// Holo 应用圆角常量
struct HoloRadius {
    /// 小圆角 - 12pt，用于小元素
    static let sm: CGFloat = 12
    /// 中等圆角 - 20pt，用于卡片
    static let md: CGFloat = 20
    /// 大圆角 - 32pt，用于按钮
    static let lg: CGFloat = 32
    /// 超大圆角 - 48pt，用于底部导航
    static let xl: CGFloat = 48
    /// 圆形 - 用于头像等
    static let full: CGFloat = 9999
}

// MARK: - 阴影系统

/// Holo 应用阴影样式
struct HoloShadow {
    /// 主按钮阴影 - 橙色发光效果
    static func primaryGlow() -> some View {
        Color.holoPrimary.opacity(0.3)
    }
    
    /// 卡片阴影 - 轻微投影
    static let card = Color.black.opacity(0.05)
    
    /// 按钮阴影 - 中等投影
    static let button = Color.black.opacity(0.1)
}