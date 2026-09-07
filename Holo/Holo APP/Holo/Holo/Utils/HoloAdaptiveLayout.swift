//
//  HoloAdaptiveLayout.swift
//  Holo
//
//  iPad/大屏自适应布局工具层（iPad 适配方案 docs/ipad-adaptation/plan.md Phase 1 基建）
//  策略：限宽居中——compact 宽度（iPhone）自然撑满、行为与不包裹完全一致；
//  regular 宽度（iPad 全屏）内容列限宽居中，两侧留白透出全局背景色。
//

import SwiftUI

/// 全局自适应布局常量（集中管理，禁止在业务视图里散落魔法数字）
enum HoloAdaptiveLayout {

    /// regular 宽度下内容列的最大宽度。
    /// iPad 竖屏 768–834pt / 横屏 1024–1366pt，内容列恒定，
    /// 横竖屏切换只改变两侧留白、不触发内容重排。
    static let contentColumnMaxWidth: CGFloat = 720

    /// 记忆长廊在 expanded 档的内容列宽度。长廊是通览型纸面（照片/卡片可拉伸），
    /// 720 在 11-13 寸横屏两侧留白过大（东林反馈「没平铺」），扩到 920；
    /// 竖屏 medium 档仍用 720 保持与手机一致的阅读栏。
    static let galleryColumnMaxWidth: CGFloat = 920

    /// 长廊章节排印的宽屏放大系数：iPad 阅读距离更远，章节头/注脚在 expanded 档
    /// 整体放大约 1.25 倍；iPhone 与 medium 档维持原设计字号。
    static func galleryTypeScale(forWindowWidth width: CGFloat?) -> CGFloat {
        isExpandedWidth(width) ? 1.25 : 1
    }

    /// 判断当前水平 size class 是否为 regular（iPad 全屏恒为 regular；iPhone 恒为 compact）
    static func isRegularWidth(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular
    }

    // MARK: - v2 宽度断点（docs/ipad-adaptation/v2-plan.md 阶段 1）

    /// expanded 档阈值：12.9 横屏（1366）/ 11 寸横屏（1160）/ 12.9 竖屏（1024）达标，
    /// 11 寸竖屏（834）与 iPhone 落在 compact/medium。
    /// 达标即启用侧边栏骨架、模块内顶部切换、通铺布局。
    static let expandedWidthThreshold: CGFloat = 1024

    /// 侧边栏宽度（v2 骨架，见设计稿 ipad-v2-0-skeleton-prototype.html）
    static let sidebarWidth: CGFloat = 232

    static func isExpandedWidth(_ width: CGFloat?) -> Bool {
        guard let width else { return false }
        return width >= expandedWidthThreshold
    }

    /// 实时窗口宽度。仅供快捷键命令、总线处理等**非视图**代码在事件瞬间读取；
    /// 视图内一律用 `holoWindowWidth` 环境（旋转时自动刷新），避免读屏幕尺寸的
    /// static 值不触发 SwiftUI 重算的问题。
    static var currentWindowWidth: CGFloat? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.bounds.width
            }
        }
        return nil
    }
}

// MARK: - 窗口宽度环境

/// 窗口宽度环境键：由 ContentView 根部 GeometryReader 注入。
/// 旋转 / 窗口变化时所有读取环境的视图自动重算。
private struct HoloWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// 当前窗口宽度（pt）。未注入（理论上不会发生）时为 nil，按最窄档处理。
    var holoWindowWidth: CGFloat? {
        get { self[HoloWindowWidthKey.self] }
        set { self[HoloWindowWidthKey.self] = newValue }
    }
}

/// 三档宽度档位：compact（手机）/ medium（iPad 窄形态与竖屏）/ expanded（宽屏通铺）
enum HoloWidthTier {
    case compact
    case medium
    case expanded

    init(width: CGFloat?, isRegular: Bool) {
        if HoloAdaptiveLayout.isExpandedWidth(width) {
            self = .expanded
        } else if isRegular {
            self = .medium
        } else {
            self = .compact
        }
    }
}

/// 限宽居中容器：iPad 上内容像「报纸栏目」居中，两侧留白显示全局背景。
struct ContentColumnContainer<Content: View>: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 内容列最大宽度，默认全局常量；个别模块需要更宽时在调用处覆盖
    private let maxWidth: CGFloat
    private let content: () -> Content

    init(
        maxWidth: CGFloat = HoloAdaptiveLayout.contentColumnMaxWidth,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            content()
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content()
        }
    }
}

// MARK: - 便捷用法

/// 限宽修饰器：regular 宽度下内容限宽居中。
/// paintsBackground=true 时自带全幅背景衬底（覆盖层/弹层没有外层背景可依赖，
/// 两侧留白须自己画，否则露出系统底色）。
/// paintsBackground=false 时只做限宽居中——模块容器已有全屏背景时用这档，
/// 避免内嵌 ignoresSafeArea 的背景层与外层 safeAreaInset（吸底 Tab 栏）互相干扰，
/// 导致 Tab 栏宽度提议也被限到列宽。
struct HoloContentColumnModifier: ViewModifier {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let maxWidth: CGFloat
    let paintsBackground: Bool

    func body(content: Content) -> some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            if paintsBackground {
                ZStack {
                    Color.holoBackground.ignoresSafeArea()
                    content
                        .frame(maxWidth: maxWidth)
                }
            } else {
                content
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
        }
    }
}

extension View {

    /// 把内容包进限宽居中容器：iPhone 无感（自然撑满），iPad 内容列居中、
    /// 两侧画全幅背景。骨架层（ContentView 三 tab）与全屏覆盖层内容统一用它。
    func holoContentColumn(maxWidth: CGFloat = HoloAdaptiveLayout.contentColumnMaxWidth,
                           paintsBackground: Bool = true) -> some View {
        modifier(HoloContentColumnModifier(maxWidth: maxWidth, paintsBackground: paintsBackground))
    }

    /// 通宵冲刺 2026-09-08：iPad 弹层宽度政策（v2 计划阶段 3 欠账）。
    /// iPad 上 .sheet 的呈现宽度跟随内容理想宽度，给表单内容套上限即可得到
    /// 居中的合理宽度弹窗；iPhone（compact）sheet 恒全宽，此修饰器无感。
    /// - form：常规表单（记账/筛选/确认类），560pt
    /// - wide：宽内容（图表/对照/编辑类），720pt
    func holoSheetWidth(_ kind: HoloSheetWidthKind = .form) -> some View {
        modifier(HoloSheetWidthModifier(kind: kind))
    }

    /// 通宵冲刺 2026-09-08：宽屏 hover 反馈（触控板/妙控键盘指针）。
    /// iPhone/无指针环境无任何效果；仅在 regular 宽度挂载，保证手机端零变化。
    func holoHover(_ style: HoverEffect = .highlight) -> some View {
        modifier(HoloHoverModifier(style: style))
    }
}

// MARK: - 弹层宽度政策（v2 阶段 3）

enum HoloSheetWidthKind {
    /// 常规表单：记账、筛选、确认类
    case form
    /// 宽内容：图表、对照列表、富文本
    case wide
    /// 自定义宽度（pt）
    case custom(CGFloat)

    var maxWidth: CGFloat {
        switch self {
        case .form: return 560
        case .wide: return 720
        case .custom(let w): return w
        }
    }
}

struct HoloSheetWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let kind: HoloSheetWidthKind

    func body(content: Content) -> some View {
        // iPhone 任意方向恒 compact（sheet 全宽直通）；iPad（regular）限宽居中。
        // 用 size class 而非窗口宽度门控：iPhone 横屏宽度可达 932pt 也必须零变化。
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            content
                .frame(maxWidth: kind.maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

// MARK: - hover 反馈基建（通宵冲刺 E 轮铺量用）

struct HoloHoverModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let style: HoverEffect

    func body(content: Content) -> some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            content.hoverEffect(style)
        } else {
            content
        }
    }
}

// MARK: - 列表-详情双栏容器（v2 设计稿范式：左 46% 列表 + 右 54% 详情）

/// expanded 档渲染「列表 | 详情」双栏（中间细分隔线），窄档只渲染列表，
/// 详情交互语义由调用方按档位分流（想法/任务/知识树共用）。
struct HoloListDetailSplit<Master: View, Detail: View>: View {
    @Environment(\.holoWindowWidth) private var windowWidth

    var masterFraction: CGFloat
    var separator: Bool
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    init(masterFraction: CGFloat = 0.46,
         separator: Bool = true,
         @ViewBuilder master: @escaping () -> Master,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.masterFraction = masterFraction
        self.separator = separator
        self.master = master
        self.detail = detail
    }

    var body: some View {
        if HoloAdaptiveLayout.isExpandedWidth(windowWidth) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    master()
                        .frame(width: geo.size.width * masterFraction)
                    if separator {
                        Rectangle()
                            .fill(Color.holoBorder.opacity(0.4))
                            .frame(width: 0.5)
                    }
                    detail()
                        .frame(width: geo.size.width * (1 - masterFraction))
                }
            }
        } else {
            master()
        }
    }
}

// MARK: - 宽屏排印分档（长廊 1.25x 的通用化，健康/目标等复用）

extension HoloAdaptiveLayout {

    /// 通用宽屏排印放大系数：与长廊同规则（expanded ×1.25）。
    /// 阅读距离更远的大屏统一提字号，iPhone 与竖屏 medium 档维持原设计。
    static func wideTypeScale(forWindowWidth width: CGFloat?) -> CGFloat {
        galleryTypeScale(forWindowWidth: width)
    }
}
