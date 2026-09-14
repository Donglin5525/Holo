//
//  HoloTodayViewModel.swift
//  Holo
//
//  「今天」统一 ViewModel（今日看板 Matter 化方案 §6.3）
//
//  - 单一快照状态源：首页入口按钮与 Today 页共用同一实例，不各查一遍数据；
//  - 监听各域数据变化通知，100ms 合并窗口去抖，一次数据变化最多一次 snapshot refresh；
//  - 保留最后成功快照作为局部降级；
//  - 所有写动作调用现有 repository/coordinator，以真实回执刷新；
//  - 动画状态不驱动 Core Data 重查。
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HoloTodayViewModel: ObservableObject {

    /// 视图状态：加载中（骨架）/ 已就绪（快照）。
    enum ViewState: Equatable {
        case loading
        case ready(HoloTodaySnapshot)
        // Equatable 不比较时间戳瞬变：ready 按 snapshot 相等判定。
    }

    @Published private(set) var state: ViewState = .loading

    /// 最近一次成功快照（局部降级与回滚验证用）。
    private(set) var lastSnapshot: HoloTodaySnapshot?

    /// 本会话「稍后」的候选键（仅会话级降级，不持久化、不永久压制）。
    @Published private(set) var postponedKeys: Set<String> = []

    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// 100ms 合并窗口：一次动作触发的多域通知折叠为一次 refresh。
    private let debounceInterval: UInt64 = 100_000_000

    init() {
        observeDataChanges()
    }

    // MARK: - 加载

    /// 首次打开：等 Core Data ready 后构建快照。
    func loadIfNeeded() async {
        guard case .loading = state else { return }
        await CoreDataStack.shared.waitUntilReady()
        TodoRepository.shared.seedDailyRitualsForToday()
        await refreshNow()
    }

    /// 立即重建快照（去抖任务取消，防止旧任务晚归覆盖）。
    func refreshNow() async {
        debounceTask?.cancel()
        refreshTask?.cancel()
        let reference = Date()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await HoloTodaySnapshotBuilder.build(referenceTime: reference)
            guard !Task.isCancelled else { return }
            self.lastSnapshot = snapshot
            // 稍后降级在 resolver 层生效：重解析焦点（不重新查库）。
            self.state = .ready(self.applyPostpone(to: snapshot))
        }
        await refreshTask?.value
    }

    // MARK: - 稍后

    /// 用户对当前主行动点「稍后」：本会话内该候选降级，重解析出次优。
    func postponeFocus() {
        guard case .ready(let snapshot) = state, let focus = snapshot.primaryFocus else { return }
        let key: String
        switch focus.action {
        case .openTask(let id):
            key = HoloTodayFocusResolver.postponeKey(for: .task(id))
        case .createTaskFromOpenLoop(let matterID, let loopID):
            key = HoloTodayFocusResolver.postponeKey(for: .matterLoop(matterID: matterID, loopID: loopID))
        case .openSchedule(let id):
            key = HoloTodayFocusResolver.postponeKey(for: .schedule(id))
        case .openMatter, .discussMatter, .none:
            return
        }
        postponedKeys.insert(key)
        guard let fresh = lastSnapshot else { return }
        state = .ready(applyPostpone(to: fresh))
    }

    /// 用会话级稍后键重解析焦点（不重查库，纯内存）。
    private func applyPostpone(to snapshot: HoloTodaySnapshot) -> HoloTodaySnapshot {
        guard !postponedKeys.isEmpty else { return snapshot }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: snapshot.referenceTime)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? snapshot.referenceTime

        // 从已冻结的候选重解析：日程 + 任务从 agenda 重建、Matter 用列表重排前的意图交给下次 refresh。
        var schedules: [HoloTodayScheduleCandidate] = []
        var tasks: [HoloTodayTaskCandidate] = []
        for item in snapshot.agenda {
            switch item.action {
            case .openSchedule(let id):
                if let start = item.timeAt {
                    schedules.append(HoloTodayScheduleCandidate(
                        id: id, title: item.title, startAt: start,
                        endAt: start.addingTimeInterval(3600), isAllDay: false
                    ))
                }
            case .openTask(let id):
                tasks.append(HoloTodayTaskCandidate(
                    id: id, title: item.title, dueAt: item.timeAt,
                    plannedForToday: item.kind == .taskPlannedToday,
                    matterID: nil, matterTitle: item.matterTitle
                ))
            default:
                break
            }
        }
        let focus = HoloTodayFocusResolver.resolve(input: HoloTodayFocusInput(
            referenceTime: snapshot.referenceTime,
            dayStart: dayStart,
            dayEnd: dayEnd,
            schedules: schedules,
            tasks: tasks,
            matters: [],
            postponedKeys: postponedKeys
        ))
        return HoloTodaySnapshot(
            referenceTime: snapshot.referenceTime,
            dayStart: snapshot.dayStart,
            dayEnd: snapshot.dayEnd,
            timeZoneIdentifier: snapshot.timeZoneIdentifier,
            generatedAt: snapshot.generatedAt,
            freshness: snapshot.freshness,
            primaryFocus: focus,
            matters: snapshot.matters,
            agenda: snapshot.agenda,
            routine: snapshot.routine,
            overview: snapshot.overview,
            sectionStates: snapshot.sectionStates
        )
    }

    // MARK: - 事件监听

    private func observeDataChanges() {
        let names = [
            Notification.Name.todoDataDidChange,
            Notification.Name.habitDataDidChange,
            Notification.Name.financeDataDidChange,
            Notification.Name.holoTaskChange,
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.scheduleDebouncedRefresh()
                }
                .store(in: &cancellables)
        }
        // Matter 仓库变化（激活/补链/生命周期）。
        HoloMatterRepository.shared.$changeToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleDebouncedRefresh()
            }
            .store(in: &cancellables)
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceInterval ?? 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }
}