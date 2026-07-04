//
//  CalendarEventsResult.swift
//  Holo
//
//  日历事件聚合结果（含每个模块的加载状态，失败不静默）
//

import Foundation

/// 单个模块的加载状态
enum CalendarModuleLoadState: Equatable {
    case loaded
    case empty
    case failed(message: String)
}

/// 日历事件聚合结果
///
/// 为什么不带 moduleStates：日历是事实回看页，单模块仓储失败若静默返回空，
/// 会让「待办仓储失败」被误读为「今天没有待办」，破坏信任。
/// 因此 Provider 对每个模块单独 do-catch，失败在 moduleStates 标 .failed，
/// UI 据此显示「部分数据暂未载入」+ retry。
struct CalendarEventsResult {
    /// 按 date 升序的事件列表
    let events: [CalendarEvent]

    /// 每个模块的加载状态
    let moduleStates: [CalendarModule: CalendarModuleLoadState]

    init(events: [CalendarEvent] = [],
         moduleStates: [CalendarModule: CalendarModuleLoadState] = [:]) {
        self.events = events
        self.moduleStates = moduleStates
    }

    /// 空结果（4 模块均未加载）
    static let empty = CalendarEventsResult()

    /// 是否存在任一模块加载失败（UI 据此决定是否显示顶部提示条）
    var hasFailure: Bool {
        moduleStates.values.contains { state in
            if case .failed = state { return true }
            return false
        }
    }

    /// 失败的模块列表（用于 retry 重新拉取）
    var failedModules: [CalendarModule] {
        moduleStates.compactMap { module, state in
            if case .failed = state { return module }
            return nil
        }
    }
}
