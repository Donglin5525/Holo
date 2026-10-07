//
//  HoloTaskCompletionCoordinator.swift
//  Holo
//
//  任务完成统一协调层（动效融合 G1 完成契约）
//  全 App 五个完成入口（任务列表 / 任务详情 / Today 议程 / Today 任务区 / 卡片子任务链）
//  共用同一条完成业务：3 秒撤回窗口内不落库，confirm 才写 completed；
//  撤回恢复「触发父任务完成的最后一个子任务」的原勾选状态，其他已勾子项保留。
//  视图只订阅状态（pending / lastConfirmed / lastFailure），不各自维护计时。
//

import Foundation
import Combine
import os.log

@MainActor
final class HoloTaskCompletionCoordinator: ObservableObject {

    // MARK: - 单例

    /// 注入惯例与 TodoRepository/TodoNotificationService 一致：共享单例 + @ObservedObject 订阅
    static let shared = HoloTaskCompletionCoordinator()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloTaskCompletionCoordinator")

    // MARK: - 状态

    struct PendingCompletion: Identifiable, Equatable {
        let id: UUID                 // = task.id
        let taskID: UUID

        enum Source: String {
            case taskList
            case taskDetail
            case todayAgenda
            case todayTaskSection
            case matterExecution
        }

        /// 发起入口（banner 语义与 Matter 事件溯源用）
        let source: Source
        /// 触发父任务完成的最后一个子任务
        let triggerCheckItemID: UUID?
        /// 该子任务触发前的原勾选状态（撤回恢复用）
        let triggerCheckItemWasChecked: Bool
        /// 分步推进合并提交意图（最后一步 + 原任务同一提交；规格 §8.2）
        struct ExecutionIntent: Equatable {
            let revisionID: UUID
            let finalStepID: UUID?
            let finalStepExpectedStateVersion: Int64?
            let userAssertion: String?
            let operationID: String
            let sourceSurface: String
        }
        let executionIntent: ExecutionIntent?
        let startedAt: Date

        init(
            id: UUID,
            taskID: UUID,
            source: Source,
            triggerCheckItemID: UUID? = nil,
            triggerCheckItemWasChecked: Bool = false,
            executionIntent: ExecutionIntent? = nil,
            startedAt: Date
        ) {
            self.id = id
            self.taskID = taskID
            self.source = source
            self.triggerCheckItemID = triggerCheckItemID
            self.triggerCheckItemWasChecked = triggerCheckItemWasChecked
            self.executionIntent = executionIntent
            self.startedAt = startedAt
        }
    }

    struct ConfirmedCompletion: Equatable {
        let taskID: UUID
        let source: PendingCompletion.Source
        /// 重复任务是否生成了下一实例
        let generatedNextOccurrence: Bool
        let confirmedAt: Date
    }

    /// 撤回窗口内的完成（跨入口共享，banner / 完成态视觉统一订阅）
    @Published private(set) var pending: PendingCompletion?

    /// 最近一次 confirm 落库成功（详情页时长面板订阅它）
    @Published private(set) var lastConfirmed: ConfirmedCompletion?

    /// confirm 落库失败（不吞错，UI 可读、可重试）
    @Published private(set) var lastFailure: (taskID: UUID, message: String)?

    // MARK: - 计时抽象

    /// 撤回窗口时长
    static let confirmDelay: TimeInterval = 3

    /// 在 fireAt 时刻调度一次 fire，返回取消闭包。
    /// 生产默认 DispatchQueue；测试注入假时钟手动触发。
    var scheduleConfirm: (_ fireAt: Date, _ fire: @escaping () -> Void) -> () -> Void =
        { fireAt, fire in
            let item = DispatchWorkItem(block: fire)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireAt.timeIntervalSinceNow), execute: item)
            return { item.cancel() }
        }

    private var cancelConfirmTimer: (() -> Void)?

    private func cancelTimer() {
        cancelConfirmTimer?()
        cancelConfirmTimer = nil
    }

    // MARK: - 请求完成（撤回窗口开启）

    /// 请求完成任务：开启 3 秒撤回窗口，计时到点才真正落库。
    /// - Parameters:
    ///   - taskID: 目标任务
    ///   - source: 发起入口（banner 语义与 Matter 事件溯源用）
    ///   - trigger: 由「子任务全勾」触发时，本次刚勾选且因此 allChecked 的子任务 ID 与勾选前状态
    ///   - repo: 任务仓储
    func requestCompletion(
        taskID: UUID,
        source: PendingCompletion.Source,
        trigger: (checkItemID: UUID, wasChecked: Bool)? = nil,
        in repo: TodoRepository
    ) {
        if let current = pending {
            if current.taskID == taskID {
                // 同一任务已在窗口内：幂等忽略，不重复开窗
                return
            }
            // 连续完成多项：显式确认上一项（可查语义，替代旧「新完成隐含确认上一项」）
            logger.log("连续完成：任务 \(current.taskID.uuidString, privacy: .public) 被显式确认，开启任务 \(taskID.uuidString, privacy: .public) 的撤回窗口")
            confirm(current, in: repo)
        }

        guard let task = repo.findTask(by: taskID), !task.completed else {
            logger.error("完成请求忽略：任务不存在或已完成 \(taskID.uuidString, privacy: .public)")
            return
        }

        pending = PendingCompletion(
            id: taskID,
            taskID: taskID,
            source: source,
            triggerCheckItemID: trigger?.checkItemID,
            triggerCheckItemWasChecked: trigger?.wasChecked ?? false,
            startedAt: Date()
        )
        cancelTimer()
        cancelConfirmTimer = scheduleConfirm(Date().addingTimeInterval(Self.confirmDelay)) { [weak self] in
            guard let self, let expiring = self.pending else { return }
            self.confirm(expiring, in: repo)
        }
    }

    /// 请求「合并提交」：最后一步 + 原任务完成在同一撤回窗口内（规格 §8.2）。
    /// 三秒内只是 pending UI，不提前保存；到期经统一事务再验并保存。
    func requestExecutionCompletion(
        taskID: UUID,
        revisionID: UUID,
        finalStepID: UUID?,
        finalStepExpectedStateVersion: Int64?,
        userAssertion: String?,
        source: PendingCompletion.Source,
        sourceSurface: String,
        in repo: TodoRepository
    ) {
        if let current = pending {
            if current.taskID == taskID && current.executionIntent != nil {
                return // 同一任务已在窗口内：幂等
            }
            logger.log("连续完成：任务 \(current.taskID.uuidString, privacy: .public) 被显式确认，开启任务 \(taskID.uuidString, privacy: .public) 的撤回窗口")
            confirm(current, in: repo)
        }

        guard let task = repo.findTask(by: taskID), !task.completed else {
            logger.error("完成请求忽略：任务不存在或已完成 \(taskID.uuidString, privacy: .public)")
            return
        }

        pending = PendingCompletion(
            id: taskID,
            taskID: taskID,
            source: source,
            executionIntent: PendingCompletion.ExecutionIntent(
                revisionID: revisionID,
                finalStepID: finalStepID,
                finalStepExpectedStateVersion: finalStepExpectedStateVersion,
                userAssertion: userAssertion,
                operationID: UUID().uuidString,
                sourceSurface: sourceSurface
            ),
            startedAt: Date()
        )
        cancelTimer()
        cancelConfirmTimer = scheduleConfirm(Date().addingTimeInterval(Self.confirmDelay)) { [weak self] in
            guard let self, let expiring = self.pending else { return }
            self.confirm(expiring, in: repo)
        }
    }

    /// 撤回当前窗口：取消计时，不落库；恢复触发子任务的原勾选状态，其他已勾子项不动。
    func undo(in repo: TodoRepository) {
        guard let current = pending else { return }
        cancelTimer()

        // 合并提交撤回：最终步骤与根都未提交，无需恢复任何状态（规格 §8.2）
        if current.executionIntent == nil,
           let triggerID = current.triggerCheckItemID,
           let task = repo.findTask(by: current.taskID),
           let item = (task.checkItems?.allObjects as? [CheckItem] ?? []).first(where: { $0.id == triggerID }) {
            do {
                if item.isChecked != current.triggerCheckItemWasChecked {
                    try repo.toggleCheckItem(item)
                }
            } catch {
                // 撤回本体已生效（任务从未落库完成），但触发子任务恢复失败必须暴露
                lastFailure = (taskID: current.taskID, message: "撤回恢复子任务失败: \(error.localizedDescription)")
                logger.error("撤回恢复子任务失败: \(error.localizedDescription, privacy: .public)")
            }
        }

        pending = nil
    }

    /// 立即确认当前窗口（显式确认场景 / 测试用）
    func confirmNow(in repo: TodoRepository) {
        guard let current = pending else { return }
        confirm(current, in: repo)
    }

    // MARK: - 确认落库

    private func confirm(_ completing: PendingCompletion, in repo: TodoRepository) {
        cancelTimer()

        guard let task = repo.findTask(by: completing.taskID) else {
            // 任务已被删除：关窗即可，无处落库
            logger.error("确认完成：任务已删除，关闭撤回窗口 \(completing.taskID.uuidString, privacy: .public)")
            pending = nil
            return
        }

        // 合并提交：最后一步 + 根完成同一事务（失败显示未完成状态并可重试，规格 §8.2）
        if let intent = completing.executionIntent {
            do {
                try HoloTaskExecutionService.shared.requestCompleteOutcome(
                    taskID: completing.taskID,
                    revisionID: intent.revisionID,
                    finalStepID: intent.finalStepID,
                    finalStepExpectedStateVersion: intent.finalStepExpectedStateVersion,
                    userAssertion: intent.userAssertion,
                    operationID: intent.operationID,
                    sourceSurface: intent.sourceSurface,
                    in: repo
                )
                pending = nil
                lastConfirmed = ConfirmedCompletion(
                    taskID: completing.taskID,
                    source: completing.source,
                    generatedNextOccurrence: false,
                    confirmedAt: Date()
                )
            } catch {
                pending = nil
                lastFailure = (taskID: completing.taskID, message: error.localizedDescription)
                logger.error("合并提交确认失败: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        do {
            let generatedNext: Bool
            if task.repeatRule != nil {
                generatedNext = try repo.completeRepeatingTask(task)
            } else {
                try repo.completeTask(task)
                generatedNext = false
            }
            pending = nil
            lastConfirmed = ConfirmedCompletion(
                taskID: completing.taskID,
                source: completing.source,
                generatedNextOccurrence: generatedNext,
                confirmedAt: Date()
            )
        } catch {
            // 失败不吞：置 lastFailure 供 UI 提示与重试，不让 UI 长留「已完成」
            pending = nil
            lastFailure = (taskID: completing.taskID, message: error.localizedDescription)
            logger.error("确认完成任务失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
