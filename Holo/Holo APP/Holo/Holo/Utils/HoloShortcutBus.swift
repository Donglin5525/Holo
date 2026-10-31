//
//  HoloShortcutBus.swift
//  Holo
//
//  硬件键盘 Cmd 组合键事件总线（iPad 适配方案 D3）
//  快捷键按钮统一挂载在 ContentView（常驻视图树），
//  事件广播给订阅方按职责响应；与 DeepLinkState 同款「单例 + @Published」模式。
//

import Foundation
import Combine

/// 全局快捷键动作。订阅方按职责响应，不认识的动作忽略。
enum HoloShortcutAction: Equatable {
    /// Cmd+N：在当前模块内新建（任务/记账/想法由 HomeView 按 activeScreen 分流）
    case newItemAtCurrentModule
    /// Cmd+F：打开当前模块的搜索（三模块搜索形态不一，按模块定制）
    case searchInCurrentModule
    /// Cmd+W：关闭当前常驻模块、回到模块首页
    case closeCurrentModule
    /// Cmd+,：打开设置
    case openSettings
    /// Cmd+1…9：侧边栏直跳（iPad v2 骨架；iPhone 由 ContentView 映射到主 tab）
    case goToSidebar(HoloSidebarDestination)
}

/// 快捷键事件：带自增 id，同一动作连按也能逐次触发订阅方。
struct HoloShortcutEvent: Equatable {
    let action: HoloShortcutAction
    let id: Int
}

final class HoloShortcutBus: ObservableObject {

    static let shared = HoloShortcutBus()

    /// ⚠️ @Published 的 `$lastEvent` 会在**每次新订阅时立即重放当前值**。
    /// 常驻视图无感；条件挂载的视图（如 Mac 模块 if/else 互斥渲染）切回即重建订阅，
    /// 会把上一条旧事件当新事件消费（2026-10-31 审计 M2：切回模块设置页自动弹出）。
    /// 非常驻消费方必须接 `.dropFirst()` 只响应订阅后的新事件。
    @Published private(set) var lastEvent: HoloShortcutEvent?

    private var nextId = 0

    func post(_ action: HoloShortcutAction) {
        nextId += 1
        lastEvent = HoloShortcutEvent(action: action, id: nextId)
    }
}
