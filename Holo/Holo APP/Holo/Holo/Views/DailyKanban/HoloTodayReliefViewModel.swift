//
//  HoloTodayReliefViewModel.swift
//  Holo
//
//  「今天减负」弹层状态机（2026-10-03 实施方案 §4/§10.4）
//
//  - input → generating → clarification(≤1) → review → adopting → adopted/failed；
//  - 手动模式无 AI 也可完整审阅采用（G2 门槛）；AI 协调器通过 ReliefGenerating 协议注入（G3）；
//  - 会话内唯一当前请求：关闭/重试/来源变化/scope 变化使旧 generation token 失效；
//  - 表达文本 ≤500 字，会话内保留、失败重试不丢、不写长期记忆。
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HoloTodayReliefViewModel: ObservableObject {

    enum Phase: Equatable {
        case input
        case generating
        case clarification(question: String, suggestedAnswers: [String])
        case review
        case adopting
        case adopted(deferredCount: Int, undoableRevisionID: UUID?)
        case failed(message: String, canRetry: Bool)
    }

    @Published private(set) var phase: Phase = .input
    @Published var situationText: String = ""
    @Published private(set) var candidate: HoloTodayReliefCandidate?
    @Published private(set) var adoptedUndoRevisionID: UUID?

    /// 生成中是否可取消（G3 接真网络后生效）。
    @Published private(set) var isCancellable: Bool = false

    /// 单会话模型调用预算（§10.4：正常 1 + 修复 1 + 追问后 1，硬上限 3）。
    private(set) var modelCallCount = 0

    /// AI 协调器（G3 注入；nil = 手动模式）。
    private var coordinator: ReliefGenerating?

    /// 递增 generation token：关闭/重试/来源变化使旧请求失效（§10.4）。
    private var generationToken = 0

    /// 用户主动编辑过的表达（会话内保留；重试不丢）。
    var hasUserEditedSituation: Bool { !situationText.isEmpty }

    static let situationTextLimit = 500

    // MARK: - 生命周期

    init(coordinator: ReliefGenerating? = nil) {
        self.coordinator = coordinator
    }

    func attachCoordinator(_ coordinator: ReliefGenerating) {
        self.coordinator = coordinator
    }

    /// 弹层关闭：作废在途请求。
    func teardown() {
        generationToken += 1
        coordinator?.cancel()
    }

    // MARK: - 表达与生成

    func updateSituation(_ text: String) {
        situationText = String(text.prefix(Self.situationTextLimit))
    }

    /// 提交表达：有协调器走 AI 生成，否则直接构建手动候选（G2 门槛：无 LLM 可完整手动安排）。
    func submit(context: HoloTodayReliefSessionContext) {
        generationToken += 1
        let token = generationToken
        if let coordinator {
            phase = .generating
            isCancellable = true
            modelCallCount += 1
            Task { [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await coordinator.generate(
                        situation: self.situationText,
                        clarificationAnswer: nil,
                        context: context
                    )
                    guard token == self.generationToken else { return } // 迟到结果作废
                    self.isCancellable = false
                    switch outcome {
                    case .proposal(let candidate):
                        self.candidate = candidate
                        self.phase = .review
                    case .clarification(let question, let answers):
                        self.phase = .clarification(question: question, suggestedAnswers: answers)
                    case .cannotHelp(let message):
                        // 保守建议：降级为手动候选，不虚构结果
                        self.candidate = Self.buildManualCandidate(context: context)
                        self.phase = .failed(message: message, canRetry: false)
                        if self.candidate != nil {
                            // 手动审阅仍可用：展示失败原因的同时进入审阅
                            self.phase = .review
                        }
                    }
                } catch {
                    guard token == self.generationToken else { return }
                    self.isCancellable = false
                    self.phase = .failed(
                        message: Self.friendlyError(error),
                        canRetry: Self.isRetryable(error)
                    )
                }
            }
        } else {
            candidate = Self.buildManualCandidate(context: context)
            phase = .review
        }
    }

    /// 追问回答（每会话最多一次；第二次仍未知 → 保守手动）。
    func answerClarification(_ answer: String, context: HoloTodayReliefSessionContext) {
        guard modelCallCount < 3 else {
            candidate = Self.buildManualCandidate(context: context)
            phase = .review
            return
        }
        generationToken += 1
        let token = generationToken
        guard let coordinator else {
            candidate = Self.buildManualCandidate(context: context)
            phase = .review
            return
        }
        phase = .generating
        modelCallCount += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await coordinator.generate(
                    situation: self.situationText,
                    clarificationAnswer: answer,
                    context: context
                )
                guard token == self.generationToken else { return }
                switch outcome {
                case .proposal(let candidate):
                    self.candidate = candidate
                    self.phase = .review
                case .clarification:
                    // 一次追问仍未知 → 退出循环走手动（R34）
                    self.candidate = Self.buildManualCandidate(context: context)
                    self.phase = .review
                case .cannotHelp(let message):
                    self.candidate = Self.buildManualCandidate(context: context)
                    self.phase = .failed(message: message, canRetry: false)
                }
            } catch {
                guard token == self.generationToken else { return }
                self.phase = .failed(message: Self.friendlyError(error), canRetry: Self.isRetryable(error))
            }
        }
    }

    /// 取消生成：作废当前 token；UI 返回输入态（保留表达）。
    func cancelGeneration() {
        generationToken += 1
        coordinator?.cancel()
        isCancellable = false
        phase = .input
    }

    func backToInput() {
        generationToken += 1
        phase = .input
    }

    // MARK: - 审阅编辑（本地即时重算；§4.3）

    /// 行操作后概括/数量/约束由 payload 直接派生，不显示模型原句。
    var reviewSummary: String {
        guard let payload = candidate?.payload else { return "" }
        let selected = payload.entries.count
        let deferred = payload.deferredTaskIDs.count
        if payload.selectionMode == .explicit, selected == 0, deferred > 0 {
            return String(localized: "今天不主动推进，先放下 \(deferred) 件事。")
        }
        if deferred > 0 {
            return String(localized: "保留 \(selected) 件推进，放下 \(deferred) 件。")
        }
        return String(localized: "保留 \(selected) 件今天推进。")
    }

    func toggleSelected(_ taskID: UUID) {
        guard var payload = candidate?.payload else { return }
        if payload.entry(for: taskID) != nil {
            payload = payload.removing(taskID: taskID)
            payload = HoloTodayPlanPayload(
                selectionMode: .explicit,
                entries: payload.entries,
                deferredTaskIDs: payload.deferredTaskIDs + [taskID],
                confirmedMustTaskIDs: payload.confirmedMustTaskIDs,
                deadlineAcknowledgements: payload.deadlineAcknowledgements
            )
        } else {
            payload = payload.withEntry(HoloTodaySelectionEntry(taskID: taskID, goal: .taskResult))
        }
        candidate?.payload = payload
    }

    /// 放下（今日到期/逾期需确认；§4.3 行内风险确认）。
    func deferTask(_ taskID: UUID, scope: HoloTodayDayScope) {
        guard var payload = candidate?.payload,
              let display = candidate?.displayFacts.tasks[taskID] else { return }
        let needsAck = HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: display.dueAt, isAllDay: display.isAllDay, scope: scope
        )
        let ack: HoloTodayDeadlineAcknowledgement?
        if needsAck,
           let fingerprint = HoloTodayReliefPolicy.deadlineFingerprint(dueDate: display.dueAt, isAllDay: display.isAllDay) {
            ack = HoloTodayDeadlineAcknowledgement(taskID: taskID, deadlineFingerprint: fingerprint)
        } else {
            ack = nil
        }
        payload = payload.deferring(taskID: taskID, acknowledgement: ack)
        candidate?.payload = payload
    }

    /// 「我知道，今天先放下」：补记风险确认（指纹来自当前事实）。
    func acknowledgeDeadlineRisk(_ taskID: UUID, scope: HoloTodayDayScope) {
        guard var payload = candidate?.payload,
              let display = candidate?.displayFacts.tasks[taskID],
              let fingerprint = HoloTodayReliefPolicy.deadlineFingerprint(dueDate: display.dueAt, isAllDay: display.isAllDay) else { return }
        var acks = payload.deadlineAcknowledgements.filter { $0.taskID != taskID }
        acks.append(HoloTodayDeadlineAcknowledgement(taskID: taskID, deadlineFingerprint: fingerprint))
        payload = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: payload.entries,
            deferredTaskIDs: payload.deferredTaskIDs,
            confirmedMustTaskIDs: payload.confirmedMustTaskIDs,
            deadlineAcknowledgements: acks
        )
        candidate?.payload = payload
    }

    /// 目标选择：整件事 / 已有步骤（重新加入已达目标项须明确选择；§7.4）。
    func setGoal(taskID: UUID, goal: HoloTodayGoal) {
        guard var payload = candidate?.payload else { return }
        payload = payload.withEntry(HoloTodaySelectionEntry(taskID: taskID, goal: goal))
        candidate?.payload = payload
    }

    /// 空库新任务标题编辑（采用前完整显示新标题；§4.5）。
    func updateNewTaskTitle(_ title: String) {
        candidate?.newTaskTitle = String(title.prefix(100))
    }

    // MARK: - 采用与撤销（§8）

    func adopt() {
        guard let candidate else { return }
        phase = .adopting
        generationToken += 1
        let token = generationToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await HoloTodayPlanService.shared.adopt(
                    candidate: HoloTodayPlanCandidate(
                        scope: candidate.scope,
                        sourceFingerprint: candidate.sourceFingerprint,
                        payload: candidate.payload,
                        newTaskTitle: candidate.newTaskTitle
                    ),
                    editedPayload: nil,
                    expectedHeads: candidate.expectedHeads,
                    operationID: UUID().uuidString,
                    currentSourceFingerprint: nil
                )
                guard token == self.generationToken else { return }
                self.adoptedUndoRevisionID = receipt.changed ? receipt.revisionID : nil
                self.phase = .adopted(
                    deferredCount: receipt.payload.deferredTaskIDs.count,
                    undoableRevisionID: receipt.changed ? receipt.revisionID : nil
                )
            } catch {
                guard token == self.generationToken else { return }
                self.phase = .failed(message: Self.friendlyError(error), canRetry: true)
            }
        }
    }

    /// 回执上的「撤销安排」（仅当前 head 对应本次采用时可撤销；§8.3）。
    func undoAdopt() {
        guard let revisionID = adoptedUndoRevisionID else { return }
        Task { [weak self] in
            guard let self else { return }
            let scope = HoloTodayDayScope.current()
            let heads = KanbanTaskSection.currentTodayPlanHeadIDs(scope: scope)
            _ = try? await HoloTodayPlanService.shared.undo(
                adoptedRevisionID: revisionID,
                scope: scope,
                expectedHeads: heads,
                operationID: UUID().uuidString
            )
            self.phase = .input
            self.candidate = nil
            self.adoptedUndoRevisionID = nil
        }
    }

    func retry() {
        candidate = nil
        phase = .input
    }

    // MARK: - 手动候选构建（G2：无 LLM 完整可用的审阅底稿）

    static func buildManualCandidate(context: HoloTodayReliefSessionContext) -> HoloTodayReliefCandidate {
        var tasks: [UUID: HoloTodayReliefDisplayFacts.TaskDisplay] = [:]
        for task in context.baseTasks {
            tasks[task.taskID] = task
        }
        let payload: HoloTodayPlanPayload
        if let current = context.currentPlanPayload, current.selectionMode == .explicit {
            payload = current
        } else {
            // 基础形态默认选择：今日到期 + 无日期近任务（可灵活推进），逾期不自动塞进主动列表
            let flexible = context.baseTasks
                .filter { !$0.isOverdue && !$0.completed }
                .map { HoloTodaySelectionEntry(taskID: $0.taskID, goal: .taskResult) }
            payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: Array(flexible.prefix(20)))
        }
        return HoloTodayReliefCandidate(
            scope: context.scope,
            sourceFingerprint: "",
            payload: payload,
            newTaskTitle: nil,
            expectedHeads: context.currentPlanHeads,
            displayFacts: HoloTodayReliefDisplayFacts(
                tasks: tasks,
                constraints: context.constraints,
                truncated: context.truncated,
                tasksAvailable: context.tasksAvailable,
                calendarAuthorized: context.calendarAuthorized
            )
        )
    }

    // MARK: - 错误文案（不暴露内部对象名）

    static func friendlyError(_ error: Error) -> String {
        if let planError = error as? HoloTodayPlanError {
            switch planError {
            case .expiredDay:
                return String(localized: "已经过了今天，重新整理一下明天的安排吧。")
            case .conflict:
                return String(localized: "安排刚好有了新变化，请重新审阅一次。")
            case .acknowledgementRequired:
                return String(localized: "有今天到期的任务需要先确认放下风险。")
            case .invalidTarget:
                return String(localized: "选择的任务刚才发生了变化，请重新审阅。")
            case .staleSource:
                return String(localized: "任务情况在审阅期间发生了变化，请重新审阅。")
            case .unavailable:
                return String(localized: "数据暂时读不到，稍后再试。")
            case .saveFailed:
                return String(localized: "保存没有成功，你的安排保持原样。")
            }
        }
        return String(localized: "这次没整理成功，可以再试一次。")
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let planError = error as? HoloTodayPlanError {
            switch planError {
            case .expiredDay:
                return false
            default:
                return true
            }
        }
        return true
    }
}

// MARK: - 会话上下文与 AI 协调器协议（G3 实现）

/// 弹层打开时冻结的会话事实（builder/仓库一次性取齐）。
@MainActor
struct HoloTodayReliefSessionContext {
    let scope: HoloTodayDayScope
    let baseTasks: [HoloTodayReliefDisplayFacts.TaskDisplay]
    let constraints: [HoloTodayPlanConstraintRow]
    let currentPlanPayload: HoloTodayPlanPayload?
    let currentPlanHeads: [UUID]
    let truncated: Bool
    let tasksAvailable: Bool
    let calendarAuthorized: Bool
    let situation: String?

}

/// AI 生成协议（G3 的 HoloTodayReliefCoordinator 实现；测试注入 stub）。
/// 取消链路必须到实际网络请求（G3 实现保证），只设 UI 标记不算取消完成。
@MainActor
protocol ReliefGenerating {
    func generate(
        situation: String,
        clarificationAnswer: String?,
        context: HoloTodayReliefSessionContext
    ) async throws -> ReliefGenerationOutcome

    func cancel()
}

@MainActor
enum ReliefGenerationOutcome {
    case proposal(HoloTodayReliefCandidate)
    case clarification(question: String, suggestedAnswers: [String])
    case cannotHelp(message: String)
}
