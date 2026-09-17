//
//  HoloLayoutPolicy.swift
//  Holo
//
//  iPad 完整可用性改造（docs/ipad-adaptation/plans/2026-09-16-Holo-iPad-完整可用性改造方案.md）
//  布局决策纯逻辑层：只做数值决策、不碰 SwiftUI，供单测与外壳共用。
//
//  三层宽度契约（方案 3.1）：
//  - windowWidth  场景窗口宽，只有外壳（ContentView）用它决定侧边栏形态；
//  - contentWidth 主内容区实得宽（扣除侧边栏与分隔线），业务模块只看它；
//  - 各栏真实宽度  列表/详情各自的最小宽与分配，卡片网格、图表按本栏宽调整。
//
//  本文件必须保持零 SwiftUI / 零项目内符号依赖，standalone 单测直接编译本文件。
//

import Foundation

/// 布局决策纯函数集（阶段 0 契约，输入输出可单测）
enum HoloLayoutPolicy {

    /// 侧边栏形态
    enum SidebarVisibility: Equatable {
        /// 常驻全宽（232pt，图标+文字）
        case persistent
        /// 收起为图标窄条（60pt，仅图标；目的地始终可见可点）
        case rail
    }

    // MARK: - 常量（单一事实源；业务视图禁止散落这些数字）

    /// 侧边栏常驻后，主内容仍须满足的最低宽度（单列舒适阅读与操作的底线）。
    /// 834 竖屏 − 232 = 602 ≥ 600 → 11 寸竖屏默认可常驻；
    /// iPad mini 744 − 232 = 512 < 600 → 默认收成窄条。
    static let minSidebarContentWidth: CGFloat = 600

    /// 侧边栏收起窄条宽度（图标 20pt + 触控目标 ≥44pt）
    static let sidebarRailWidth: CGFloat = 60

    /// 双栏就绪线：360 列表 + 440 详情 + 60 间隔与内边距（方案建议从约 860 验证）。
    /// 与 `HoloAdaptiveLayout.expandedWidthThreshold` 同值——模块级 expanded 判定
    /// 即「主内容实得宽度足以双栏」。
    static let splitReadyWidth: CGFloat = 860

    /// 列表栏（master）最小宽
    static let masterColumnMinWidth: CGFloat = 360
    /// 列表栏（master）最大宽：更宽的窗口把余量让给详情栏
    static let masterColumnMaxWidth: CGFloat = 520
    /// 详情栏（detail）最小宽
    static let detailColumnMinWidth: CGFloat = 440

    // MARK: - 侧边栏决策

    /// 窗口是否宽到可以让侧边栏常驻（扣 232 后主内容仍 ≥ 600）。
    /// 调用方：ContentView 外壳自动策略；用户手动收起/展开后优先用户选择。
    static func prefersPersistentSidebar(windowWidth: CGFloat) -> Bool {
        windowWidth - HoloAdaptiveLayoutSidebarWidth >= minSidebarContentWidth
    }

    // MARK: - 内容宽度推导

    /// 给定窗口宽与侧边栏形态，主内容区实得宽度。
    /// 分隔线 0.5pt 计入扣除（与 ContentView 实际渲染一致）。
    static func contentWidth(windowWidth: CGFloat, sidebar: SidebarVisibility?) -> CGFloat {
        guard let sidebar else { return windowWidth }
        let sidebarInset: CGFloat
        switch sidebar {
        case .persistent:
            sidebarInset = HoloAdaptiveLayoutSidebarWidth
        case .rail:
            sidebarInset = sidebarRailWidth
        }
        return windowWidth - sidebarInset - 0.5
    }

    // MARK: - 双栏分配

    /// 主内容实得宽是否足以双栏（expanded 判定的单一事实源）。
    static func isSplitReady(contentWidth: CGFloat?) -> Bool {
        guard let contentWidth else { return false }
        return contentWidth >= splitReadyWidth
    }

    /// 双栏下列表栏宽度：按 0.46 比例起算，钳制在 [360, 520]。
    /// 详情栏拿剩余全部（860 时 ≥ 440，1134 时 ≥ 614），宽屏余量归详情。
    static func masterColumnWidth(forSplitWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.46, masterColumnMinWidth), masterColumnMaxWidth)
    }

    /// 双栏下详情栏宽度（用于布局断言，渲染时详情栏直接弹性撑满）
    static func detailColumnWidth(forSplitWidth width: CGFloat) -> CGFloat {
        width - masterColumnWidth(forSplitWidth: width)
    }
}

/// 侧边栏常驻宽度常量。真实定义在 `HoloAdaptiveLayout.sidebarWidth`（SwiftUI 层）；
/// 本文件为保持零 SwiftUI 依赖，此处按同一数值复制并在单测中与业务常量对账。
/// 修改任一处必须同步另一处。
let HoloAdaptiveLayoutSidebarWidth: CGFloat = 232
