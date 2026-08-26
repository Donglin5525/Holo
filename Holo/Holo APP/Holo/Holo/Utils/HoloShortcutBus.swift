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
    /// Cmd+F：打开当前模块的搜索（二期接入：三模块搜索形态不一，须按模块定制）
    case searchInCurrentModule
    /// Cmd+W：关闭当前常驻模块、回到模块首页
    case closeCurrentModule
    /// Cmd+,：打开设置
    case openSettings
}

/// 快捷键事件：带自增 id，同一动作连按也能逐次触发订阅方。
struct HoloShortcutEvent: Equatable {
    let action: HoloShortcutAction
    let id: Int
}

final class HoloShortcutBus: ObservableObject {

    static let shared = HoloShortcutBus()

    @Published private(set) var lastEvent: HoloShortcutEvent?

    private var nextId = 0

    func post(_ action: HoloShortcutAction) {
        nextId += 1
        lastEvent = HoloShortcutEvent(action: action, id: nextId)
    }
}
