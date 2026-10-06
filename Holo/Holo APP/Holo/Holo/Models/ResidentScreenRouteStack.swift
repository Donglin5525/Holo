//
//  ResidentScreenRouteStack.swift
//  Holo
//
//  首页常驻模块的统一导航栈。
//

import Foundation

/// HomeView 可以承载的全屏模块。
enum ActiveScreen: String, Identifiable, CaseIterable {
    case ai, finance, habits, tasks, memoryGallery, health, thoughts

    var id: String { rawValue }
}

/// 单个常驻模块路由。独立 ID 让同一模块在不同会话轮次里保持视图身份稳定。
struct ResidentScreenRoute: Identifiable, Equatable {
    let id: UUID
    let screen: ActiveScreen

    init(id: UUID = UUID(), screen: ActiveScreen) {
        self.id = id
        self.screen = screen
    }
}

/// 常驻模块导航栈：挂载集合 + 导航历史两个正交概念。
///
/// - `routes` 是**挂载集合**：模块进入过即在列（每个模块至多一条路由），
///   驱动视图生命周期。模块一旦挂载就不再销毁——跨模块切换只切换可见性，
///   滚动位置、聊天现场、日期筛选等状态跨切换保留，重入不付重建成本。
/// - `history` 是**导航历史**：决定当前可见模块（末位）与 ⌘W / 右滑的返回顺序。
///   历史上销毁式模型里「首页新入口清空旧链路」清掉的是历史，不是挂载。
///
/// 这样侧边栏在七个模块间往返不再触发销毁+全量重建（切换卡顿与状态丢失的根因），
/// 而返回首页也只是隐藏模块，重入瞬时直达。
struct ResidentScreenRouteStack: Equatable {
    /// 已挂载模块（按首次挂载顺序；ForEach 生命周期与 zIndex 依据）
    private(set) var routes: [ResidentScreenRoute] = []

    /// 导航历史（元素均为 routes 中已挂载的 screen；末位 = 当前可见模块）
    private(set) var history: [ActiveScreen] = []

    var current: ActiveScreen? {
        history.last
    }

    /// 首页直接入口：建立新的根链路（清空历史），模块视图复用既有挂载。
    mutating func openRoot(_ screen: ActiveScreen) {
        mountIfNeeded(screen)
        history = [screen]
    }

    /// 模块间跳转：保留来源；目标在历史中时弹回既有位置，不重复入栈。
    mutating func navigate(to screen: ActiveScreen) {
        guard current != screen else { return }

        if let existingIndex = history.firstIndex(of: screen) {
            history.removeSubrange(history.index(after: existingIndex)..<history.endIndex)
        } else {
            mountIfNeeded(screen)
            history.append(screen)
        }
    }

    /// 关闭当前模块：弹出历史（回到来源模块或首页），模块保持挂载。
    @discardableResult
    mutating func dismissCurrent() -> ActiveScreen? {
        guard !history.isEmpty else { return nil }
        history.removeLast()
        return current
    }

    /// 清空导航历史回到首页；已挂载模块保持常驻（隐藏不销毁），重入瞬时直达。
    mutating func dismissAll() {
        history.removeAll()
    }

    private mutating func mountIfNeeded(_ screen: ActiveScreen) {
        guard !routes.contains(where: { $0.screen == screen }) else { return }
        routes.append(ResidentScreenRoute(screen: screen))
    }
}
