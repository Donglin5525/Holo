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
    
    // MARK: - 背景色 (支持 Dark Mode)
    /// 主背景色 - 米白色调 / 深色模式
    static let holoBackground = Color("Background")
    /// 卡片背景色
    static let holoCardBackground = Color("CardBackground")
    /// 嵌套卡片背景色：用于已经位于卡片容器内的次级信息块，避免深色模式下与父卡片融为一体
    static let holoNestedCardBackground = Color("NestedCardBackground")
    
    // MARK: - 文字颜色 (支持 Dark Mode)
    /// 主文字颜色 - 深灰色 / 浅色模式
    static let holoTextPrimary = Color("TextPrimary")
    /// 次要文字颜色 - 中灰色
    static let holoTextSecondary = Color("TextSecondary")
    /// 占位符文字
    static let holoTextPlaceholder = Color("TextPlaceholder")
    
    // MARK: - 功能性颜色
    /// 成功状态 - 绿色
    static let holoSuccess = Color(red: 34/255, green: 197/255, blue: 94/255)  // #22C55E
    /// 成功状态深色（渐变收尾用）
    static let holoSuccessDark = Color(red: 22/255, green: 163/255, blue: 74/255)  // #16A34A
    /// 成功状态浅色背景
    static let holoSuccessLight = Color(red: 209/255, green: 250/255, blue: 229/255)  // #D1FAE5
    /// 错误/支出状态 - 红色
    static let holoError = Color(red: 239/255, green: 68/255, blue: 68/255)  // #EF4444
    /// 错误状态深色（渐变收尾用）
    static let holoErrorDark = Color(red: 220/255, green: 38/255, blue: 38/255)  // #DC2626
    /// 错误状态浅色背景
    static let holoErrorLight = Color(red: 254/255, green: 226/255, blue: 226/255)  // #FEE2E2
    /// 信息提示 - 蓝色
    static let holoInfo = Color(red: 96/255, green: 165/255, blue: 250/255)  // #60A5FA
    /// 紫色装饰
    static let holoPurple = Color(red: 192/255, green: 132/255, blue: 252/255)  // #C084FC
    /// AI 专属色 - 紫色，用于 AI 自动整理等智能功能入口标识，与品牌橙色区分
    static let holoAI = Color(red: 124/255, green: 92/255, blue: 252/255)  // #7C5CFC
    
    // MARK: - 图表颜色
    /// 图表颜色系列（12 色调色板，色相均匀分布，保证视觉可区分）
    static let holoChart1  = Color(red: 59/255,  green: 130/255, blue: 246/255)  // #3B82F6 蓝
    static let holoChart2  = Color(red: 249/255, green: 115/255, blue: 22/255)   // #F97316 橙
    static let holoChart3  = Color(red: 34/255,  green: 197/255, blue: 94/255)   // #22C55E 绿
    static let holoChart4  = Color(red: 239/255, green: 68/255,  blue: 68/255)   // #EF4444 红
    static let holoChart5  = Color(red: 139/255, green: 92/255,  blue: 246/255)  // #8B5CF6 紫
    static let holoChart6  = Color(red: 20/255,  green: 184/255, blue: 166/255)  // #14B8A6 青
    static let holoChart7  = Color(red: 236/255, green: 72/255,  blue: 153/255)  // #EC4899 粉
    static let holoChart8  = Color(red: 234/255, green: 179/255, blue: 8/255)    // #EAB308 黄
    static let holoChart9  = Color(red: 99/255,  green: 102/255, blue: 241/255)  // #6366F1 靛
    static let holoChart10 = Color(red: 6/255,   green: 182/255, blue: 212/255)  // #06B6D4 天蓝
    static let holoChart11 = Color(red: 244/255, green: 63/255,  blue: 94/255)   // #F43F5E 玫红
    static let holoChart12 = Color(red: 132/255, green: 204/255, blue: 22/255)   // #84CC16 黄绿

    /// 预定义调色板（12 色，按最大色相间距排列，相邻色相差 ≥107°）
    /// 排列逻辑：蓝→黄→紫→绿→橙→天蓝→玫红→青→红→靛→黄绿→粉
    private static let chartPalette: [Color] = [
        .holoChart1, .holoChart8, .holoChart5, .holoChart3,
        .holoChart2, .holoChart10, .holoChart11, .holoChart6,
        .holoChart4, .holoChart9, .holoChart12, .holoChart7
    ]

    /// 生成指定数量的图表颜色（12 色内用预定义调色板，超出用黄金角度补充）
    static func holoChartColors(count: Int) -> [Color] {
        guard count > 0 else { return [] }
        if count <= chartPalette.count {
            return Array(chartPalette.prefix(count))
        }
        // 超出 12 色时，用黄金角度生成补充色
        return chartPalette + (chartPalette.count..<count).map { i in
            let hue = (Double(i) * 137.508).truncatingRemainder(dividingBy: 360) / 360
            return Color(hue: hue, saturation: 0.7, brightness: 0.85)
        }
    }

    // MARK: - 热力图色阶（Heatmap）

    /// 热力图色阶类型：暖橙（活跃/品牌色）或冷蓝（记录数/中性）
    enum HoloHeatmapPalette {
        case warm   // 活跃热力图（记忆），从背景色渐变到品牌橙
        case cool   // 记录热力图（月历），从背景色渐变到信息蓝
    }

    /// 热力图指定等级（0=空档，1...5=由浅到深）的色值。
    /// Light/Dark Mode 使用独立色阶，避免深色界面出现亮白色块。
    /// 这里是全 App 热力图色阶的唯一来源，禁止在组件里硬编码 hex。
    static func holoHeatmapColor(level: Int, palette: HoloHeatmapPalette, colorScheme: ColorScheme) -> Color {
        Color(hex: holoHeatmapHex(level: level, palette: palette, colorScheme: colorScheme))
    }

    private static func holoHeatmapHex(level: Int, palette: HoloHeatmapPalette, colorScheme: ColorScheme) -> String {
        switch palette {
        case .warm:
            // 活跃热力图：0=背景底色，1...5 由浅到深的暖橙
            switch colorScheme {
            case .dark:
                switch level {
                case 0:      return "#302925"
                case 1:      return "#302925"
                case 2:      return "#4A3028"
                case 3:      return "#663A2C"
                case 4:      return "#84462F"
                default:     return "#A95634"
                }
            default:
                switch level {
                case 0:      return "#F5F2ED"
                case 1:      return "#F5F2ED"
                case 2:      return "#FFD6C7"
                case 3:      return "#FFB499"
                case 4:      return "#FF9B7A"
                default:     return "#FF8C66"
                }
            }
        case .cool:
            // 记录热力图：0=空档，1...5 由浅到深的冷蓝
            switch colorScheme {
            case .dark:
                switch level {
                case 0:      return "#25282D"
                case 1:      return "#283342"
                case 2:      return "#2B4055"
                case 3:      return "#2F4E68"
                default:     return "#345D7C"
                }
            default:
                switch level {
                case 0:      return "#F6F8FB"
                case 1:      return "#EAF2FF"
                case 2:      return "#D9ECFF"
                case 3:      return "#CFE7F7"
                default:     return "#C8DDF8"
                }
            }
        }
    }

    
    // MARK: - 卡片/按钮背景 (支持 Dark Mode)
    /// 毛玻璃背景色
    static let holoGlassBackground = Color("GlassBackground")
    /// 边框颜色
    static let holoBorder = Color("Border")
    /// 分隔线颜色
    static let holoDivider = Color("Divider")
    
    // MARK: - 分类颜色（与前端原型对齐）
    /// 餐饮 - 橙色
    static let holoCategoryDining = Color(red: 249/255, green: 115/255, blue: 22/255)  // #F97316
    /// 交通 - 绿色
    static let holoCategoryTransport = Color(red: 16/255, green: 185/255, blue: 129/255)  // #10B981
    /// 购物 - 靛蓝色
    static let holoCategoryShopping = Color(red: 99/255, green: 102/255, blue: 241/255)  // #6366F1
    /// 咖啡 - 橙色
    static let holoCategoryCoffee = Color(red: 251/255, green: 146/255, blue: 60/255)  // #FB923C
    /// 日用 - 绿色
    static let holoCategoryGrocery = Color(red: 34/255, green: 197/255, blue: 94/255)  // #22C55E
    /// 公用事业 - 蓝色
    static let holoCategoryUtilities = Color(red: 59/255, green: 130/255, blue: 246/255)  // #3B82F6
    /// 娱乐 - 粉色
    static let holoCategoryEntertain = Color(red: 236/255, green: 72/255, blue: 153/255)  // #EC4899
    /// 居住 - 靛蓝色
    static let holoCategoryHousing = Color(red: 79/255, green: 70/255, blue: 229/255)  // #4F46E5
    /// 工资 - 绿色
    static let holoCategorySalary = Color(red: 34/255, green: 197/255, blue: 94/255)  // #22C55E
    /// 奖金 - 绿色
    static let holoCategoryBonus = Color(red: 22/255, green: 163/255, blue: 74/255)  // #16A34A
}

// MARK: - 字体系统

/// Holo 应用字体系统
/// 统一管理字体大小和样式
extension Font {
    /// 超大标题，用于金额显示；跟随系统动态字体缩放。
    static let holoAmount = Font.largeTitle.weight(.bold)
    
    /// 大标题，用于主要标题；跟随系统动态字体缩放。
    static let holoTitle = Font.title.weight(.bold)
    
    /// 页面标题，用于页面头部；跟随系统动态字体缩放。
    static let holoHeading = Font.title3.weight(.semibold)
    
    /// 正文，用于主要内容；跟随系统动态字体缩放。
    static let holoBody = Font.body.weight(.medium)
    
    /// 辅助文字，用于说明文字；跟随系统动态字体缩放。
    static let holoCaption = Font.subheadline
    
    /// 小标签，用于按钮标签；跟随系统动态字体缩放。
    static let holoLabel = Font.caption.weight(.medium)
    
    /// 超小标签，用于底部导航标签；跟随系统动态字体缩放。
    static let holoTinyLabel = Font.caption2.weight(.medium)
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
    /// 小圆角 - 8pt，用于小元素
    static let sm: CGFloat = 8
    /// 中等圆角 - 12pt，用于按钮
    static let md: CGFloat = 12
    /// 大圆角 - 16pt，用于卡片
    static let lg: CGFloat = 16
    /// 超大圆角 - 24pt，用于弹窗
    static let xl: CGFloat = 24
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
    
    /// 卡片阴影 - 轻微投影 (支持 Dark Mode)
    static let card = Color("Shadow")

    /// 按钮阴影 - 中等投影 (Dark Mode 下更明显)
    static let button = Color("Shadow")
    
    /// 浮动按钮阴影
    static let float = Color.holoPrimary.opacity(0.3)
}

// MARK: - Holo Plus 主题

/// Holo Plus 模块的统一主题 token。
/// 全 App 任何 Plus 相关页面的配色只从这里取，禁止再内联金色/橙色 hex。
/// 配色以品牌橙（holoPrimary #F46D38）为基调，深底卡片保留高级感的暖调深色。
enum HoloPlusTheme {
    // MARK: 深色卡片底（状态卡 / 入口卡）
    /// 三段暖调深色渐变（去掉了原来的冷紫调，统一到橙系暖底）
    static let darkGradient = LinearGradient(
        colors: [
            Color(hex: "#1C1614"),  // 暖深褐
            Color(hex: "#2A1B15"),  // 深咖
            Color(hex: "#321E18")   // 焦糖暗调
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: 深底上的文字色
    /// 深底上的主文字 —— 暖白偏橙
    static let accentText = Color(hex: "#FFE8D5")
    /// 深底上的次要文字
    static let subtleText = Color(hex: "#F0C9A8").opacity(0.82)

    // MARK: 品牌橙元素（直接复用设计系统已有色）
    /// PLUS 徽章底色
    static let badgeBg = Color.holoPrimaryLight   // #FED7AA
    /// PLUS 徽章字色
    static let badgeText = Color.holoPrimaryDark   // #EA580C
    /// 右上角光晕
    static let glowColor = Color.holoPrimary.opacity(0.28)
    /// 深底卡片描边
    static let strokeColor = Color.holoPrimaryLight.opacity(0.45)

    // MARK: 浅底卡片（对比表 / 付费墙卡片）
    /// Plus 列高亮底色
    static let plusColumnTint = Color.holoPrimary.opacity(0.06)
    /// Plus 列数字色
    static let plusValueColor = Color.holoPrimary
}

// MARK: - 卡片样式

/// Holo 标准卡片样式
/// 统一全 App 卡片外观：卡片底色 + 16pt 圆角 + 0.5pt 半透明描边 + 轻投影
/// 内容 padding 由调用方自行控制，本修饰符只管外观
struct HoloCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
    }
}

/// Holo 嵌套卡片样式
///
/// 用于卡片容器内的次级卡片。嵌套层级必须使用独立表面色，
/// 否则深色模式下即使有轻微描边，也很难判断信息块的边界。
struct HoloNestedCardStyle: ViewModifier {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = HoloRadius.lg) {
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background(Color.holoNestedCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.holoBorder.opacity(0.6), lineWidth: 0.75)
            }
            .shadow(color: HoloShadow.card.opacity(0.55), radius: 5, y: 2)
    }
}

extension View {
    /// 应用 Holo 标准卡片外观
    func holoCard() -> some View {
        modifier(HoloCardStyle())
    }

    /// 应用卡片容器内的次级卡片外观
    func holoNestedCard(cornerRadius: CGFloat = HoloRadius.lg) -> some View {
        modifier(HoloNestedCardStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - 习惯磁贴配色

extension Color {
    /// 习惯磁贴未完成态的淡底浓度（习惯色叠在卡底上：浅色 8% / 深色 16%）
    static func habitTileTintOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.16 : 0.08
    }

    /// 习惯磁贴未完成态的描边浓度
    static func habitTileBorderOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.30 : 0.16
    }
}
