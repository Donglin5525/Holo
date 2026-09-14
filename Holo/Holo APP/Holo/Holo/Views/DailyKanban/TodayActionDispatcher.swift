//
//  TodayActionDispatcher.swift
//  Holo
//
//  类型化 action 到现有页面/仓库的唯一分发边界（今日看板 Matter 化方案 §10.2）
//
//  1. 验证目标仍存在；2. 验证 Matter revision / task 状态仍匹配；
//  3. 执行或导航；4. 接收真实回执；5. 触发快照刷新；
//  6. 失败保留原卡并显示局部错误；7. 幂等动作防双击重复写入。
//

import Foundation
import SwiftUI
import Combine

/// Today 内部类型化路由（§10.1）。
nonisolated enum HoloTodayRoute: Hashable {
    case matterList
    case matterDetail(UUID, focusOpenLoopID: UUID?)
    case taskDetail(UUID)
    case scheduleDetail(String)
}

@MainActor
final class TodayActionDispatcher: ObservableObject {

    /// Today 内部 NavigationStack 路径。
    @Published var path: [HoloTodayRoute] = []
    /// 日程详情 sheet。
    @Published var scheduleDetailItem: ScheduleItem?
    /// 执行中的动作（按钮 loading 与防双击）。
    @Published var inFlightAction: HoloTodayAction?
    /// 局部错误（保留原卡，按钮行显示）。
    @Published var localErrorMessage: String?

    /// 进入 scoped Chat（由 HomeView 提供；先存上下文再关闭 Today）。
    var onOpenChatWithMatter: ((UUID) -> Void)?
    private let viewModel: HoloTodayViewModel

    init(viewModel: HoloTodayViewModel) {
        self.viewModel = viewModel
    }

    /// 唯一入口：卡片/行只管把 action 交进来。
    func perform(_ action: HoloTodayAction) {
        guard inFlightAction == nil else { return } // 防双击重复写入
        localErrorMessage = nil
        switch action {
        case .openTask(let taskID):
            guard TodoRepository.shared.findTask(by: taskID) != nil else {
                localErrorMessage = String(localized: "这条任务已被删除")
                Task { await viewModel.refreshNow() }
                return
            }
            path.append(.taskDetail(taskID))

        case .openSchedule(let scheduleID):
            if let item = findSchedule(scheduleID) {
                scheduleDetailItem = item
            } else {
                localErrorMessage = String(localized: "日程暂时无法打开")
            }

        case .openMatter(let matterID, let focusLoopID):
            guard HoloMatterRepository.shared.matter(id: matterID) != nil else {
                localErrorMessage = String(localized: "这件事不存在或已删除")
                Task { await viewModel.refreshNow() }
                return
            }
            path.append(.matterDetail(matterID, focusOpenLoopID: focusLoopID))

        case .createTaskFromOpenLoop(let matterID, let openLoopID):
            inFlightAction = action
            Task { [weak self] in
                defer { self?.inFlightAction = nil }
                do {
                    _ = try await HoloMatterLinkingCoordinator.createTaskFromOpenLoop(
                        matterID: matterID,
                        openLoopID: openLoopID,
                        repository: .shared
                    )
                    await self?.viewModel.refreshNow()
                } catch {
                    self?.localErrorMessage = String(localized: "没有加入成功，可以再试一次")
                }
            }

        case .discussMatter(let matterID):
            onOpenChatWithMatter?(matterID)

        case .none:
            break
        }
    }

    private func findSchedule(_ scheduleID: String) -> ScheduleItem? {
        let eventID = scheduleID.split(separator: "|").first.map(String.init) ?? scheduleID
        return ScheduleStore.shared.cachedSchedules(onDay: Date()).first {
            $0.id == scheduleID || $0.eventIdentifier == eventID
        }
    }
}