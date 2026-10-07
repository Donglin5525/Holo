//
//  HoloTodayReliefCoordinator.swift
//  Holo
//
//  「今天减负」AI 协调器（2026-10-03 实施方案 §10）
//
//  - 冻结输入（scope/heads/任务/步骤/日程/可用性）→ canonical 指纹；
//  - 专用 purpose today_relief_plan 单轮 JSON 契约（proposal/clarification/cannotHelp）；
//  - 严格解析：code fence 剥离、必填缺失即错、未知 ID/跨任务 stepID 本地拒绝；
//  - 一次生成最多一次结构修复（网络/额度/鉴权失败不触发修复）；
//  - 取消传导到实际请求 Task；迟到结果由调用方 generation token 作废；
//  - 模型只给建议：确认指纹、payload 校验、写入全部在本地（§6）。
//

import Foundation
import CryptoKit
import EventKit

// MARK: - 请求/响应契约（§10.2/§10.3）

nonisolated struct HoloTodayReliefAIRequest: Encodable, Sendable {
    struct TaskInput: Encodable, Sendable {
        let id: UUID
        let title: String
        let effectiveDueAt: Date?
        let isAllDay: Bool
        let selected: Bool
        let durationMinutes: Int?
        let currentStep: StepInput?

        struct StepInput: Encodable, Sendable {
            let id: UUID
            let action: String
            let doneWhen: String?
            let contentFingerprint: String
        }
    }

    let schemaVersion: Int
    let requestID: String
    let scopeKey: String
    let referenceTime: Date
    let sourceFingerprint: String
    let situation: String
    /// 结构修复轮：上一轮输出的问题说明（仅修复时携带）。
    let repairNote: String?
    let clarificationTurn: Int
    let tasks: [TaskInput]
    let constraints: [String]
    let availability: Availability

    struct Availability: Encodable, Sendable {
        let tasks: String
        let calendar: String
        let execution: String
        let truncated: Bool
    }
}

nonisolated struct HoloTodayReliefAIResponse: Decodable, Sendable, Equatable {
    struct Selection: Decodable, Sendable, Equatable {
        let taskID: UUID
        let goal: GoalDTO
        let reasonCode: String?
        let evidenceRefs: [String]?
    }
    struct GoalDTO: Decodable, Sendable, Equatable {
        let kind: String
        let stepID: UUID?
    }
    struct Warning: Decodable, Sendable, Equatable {
        let code: String
        let taskIDs: [UUID]?
    }
    struct NewTask: Decodable, Sendable, Equatable {
        let title: String
        let description: String?
    }

    let schemaVersion: Int
    let kind: String
    let requestID: String?
    let scopeKey: String?
    let sourceFingerprint: String?
    let summary: String?
    let selected: [Selection]?
    let deferredTaskIDs: [UUID]?
    let warnings: [Warning]?
    let newTask: NewTask?
    let question: String?
    let suggestedAnswers: [String]?
    let reasonCode: String?
    let message: String?
}

// MARK: - 协调器错误

nonisolated enum HoloTodayReliefError: Error, Equatable {
    /// 非法模型输出（解析失败/契约不符/未知 ID）——一次修复机会后仍失败。
    case invalidModelOutput(String)
    /// 网络层失败（不触发结构修复）。
    case network(String)
    /// 输出引用了不存在的任务/步骤或跨任务步骤（R31）。
    case unknownReference(String)
}

// MARK: - 协调器

@MainActor
final class HoloTodayReliefCoordinator: ReliefGenerating {

    @MainActor static func makeDefault() -> HoloTodayReliefCoordinator {
        let servicing: HoloTodayReliefModelServicing
        if let provider = HoloBackendEnvironment.makeDefaultProvider() as? HoloTodayReliefModelServicing {
            servicing = provider
        } else {
            servicing = UnavailableTodayReliefService()
        }
        return HoloTodayReliefCoordinator(servicing: servicing)
    }

    private let servicing: HoloTodayReliefModelServicing
    /// 在途请求（取消传导到实际网络调用；§10.4）。
    private var inflight: Task<String, Error>?

    init(servicing: HoloTodayReliefModelServicing) {
        self.servicing = servicing
    }

    // MARK: ReliefGenerating

    func generate(
        situation: String,
        clarificationAnswer: String?,
        context: HoloTodayReliefSessionContext
    ) async throws -> ReliefGenerationOutcome {
        let requestID = UUID().uuidString
        let fingerprint = Self.sourceFingerprint(context: context, situation: situation)
        let encoder = JSONEncoder.dateEncodingStrategyCustomISO8601()
        let body: String
        do {
            let dto = Self.makeRequestDTO(
                context: context,
                situation: situation,
                clarificationAnswer: clarificationAnswer,
                requestID: requestID,
                fingerprint: fingerprint,
                repairNote: nil
            )
            let data = try encoder.encode(dto)
            body = String(decoding: data, as: UTF8.self)
        } catch {
            throw HoloTodayReliefError.invalidModelOutput("requestEncodeFailed")
        }

        let firstRound: String
        do {
            firstRound = try await perform(bodyJSON: body, usageActionId: "today-relief-\(requestID)")
        } catch let error as HoloTodayReliefError {
            throw error
        } catch {
            throw HoloTodayReliefError.network(error.localizedDescription)
        }

        do {
            let response = try Self.parse(firstRound)
            return try Self.materialize(
                response: response,
                context: context,
                requestID: requestID,
                fingerprint: fingerprint
            )
        } catch let error as HoloTodayReliefError {
            // 一次结构修复：同 requestID、同额度动作，附带问题说明（§10.4）
            guard case .invalidModelOutput = error else { throw error }
            let repairDTO = Self.makeRequestDTO(
                context: context,
                situation: situation,
                clarificationAnswer: clarificationAnswer,
                requestID: requestID,
                fingerprint: fingerprint,
                repairNote: "\(error)"
            )
            let repairBody: String
            do {
                let data = try encoder.encode(repairDTO)
                repairBody = String(decoding: data, as: UTF8.self)
            } catch {
                throw error
            }
            let secondRound = try await perform(bodyJSON: repairBody, usageActionId: "today-relief-\(requestID)")
            let repaired = try Self.parse(secondRound)
            return try Self.materialize(
                response: repaired,
                context: context,
                requestID: requestID,
                fingerprint: fingerprint
            )
        }
    }

    func cancel() {
        inflight?.cancel()
        inflight = nil
    }

    // MARK: - 内部

    private func perform(bodyJSON: String, usageActionId: String) async throws -> String {
        let servicing = self.servicing
        let task = Task<String, Error> {
            try await servicing.sendTodayReliefPlan(bodyJSON: bodyJSON, usageActionId: usageActionId)
        }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    // MARK: 请求构建

    nonisolated static func makeRequestDTO(
        context: HoloTodayReliefSessionContext,
        situation: String,
        clarificationAnswer: String?,
        requestID: String,
        fingerprint: String,
        repairNote: String?
    ) -> HoloTodayReliefAIRequest {
        var selectedIDs = Set<UUID>()
        if let payload = context.currentPlanPayload, payload.selectionMode == .explicit {
            selectedIDs = Set(payload.entries.map(\.taskID))
        }
        var tasks: [HoloTodayReliefAIRequest.TaskInput] = []
        for display in context.baseTasks {
            tasks.append(HoloTodayReliefAIRequest.TaskInput(
                id: display.taskID,
                title: String(display.title.prefix(100)),
                effectiveDueAt: display.dueAt,
                isAllDay: display.isAllDay,
                selected: selectedIDs.contains(display.taskID),
                durationMinutes: nil,
                currentStep: display.currentStepID.map { stepID in
                    HoloTodayReliefAIRequest.TaskInput.StepInput(
                        id: stepID,
                        action: String(display.currentStepAction ?? "").prefix(100).description,
                        doneWhen: nil,
                        contentFingerprint: display.currentStepFingerprint ?? ""
                    )
                }
            ))
        }
        return HoloTodayReliefAIRequest(
            schemaVersion: 1,
            requestID: requestID,
            scopeKey: context.scope.scopeKey,
            referenceTime: Date(),
            sourceFingerprint: fingerprint,
            situation: situation,
            repairNote: repairNote,
            clarificationTurn: clarificationAnswer == nil ? 0 : 1,
            tasks: tasks,
            constraints: context.constraints.map(\.title),
            availability: .init(
                tasks: context.tasksAvailable ? "available" : "unavailable",
                calendar: context.calendarAuthorized ? "authorized" : "notAuthorized",
                execution: "available",
                truncated: context.truncated
            )
        )
    }

    /// 输入指纹（§10.1）：scope/heads/任务身份内容日期完成可见性/步骤/可用性/表达。
    /// 不包含不断前进的 Date()（referenceTime 不进指纹）。
    nonisolated static func sourceFingerprint(context: HoloTodayReliefSessionContext, situation: String) -> String {
        var basis = "scope=\(context.scope.scopeKey)"
        basis += "|heads=\(context.currentPlanHeads.map(\.uuidString).sorted().joined(separator: ","))"
        for task in context.baseTasks.sorted(by: { $0.taskID.uuidString < $1.taskID.uuidString }) {
            var dueStamp = "none"
            if let due = task.dueAt { dueStamp = String(Int(due.timeIntervalSince1970)) }
            var stepStamp = "none"
            if let stepID = task.currentStepID { stepStamp = "\(stepID.uuidString)|\(task.currentStepFingerprint ?? "")" }
            basis += "|t=\(task.taskID.uuidString),\(task.title),\(dueStamp),\(task.isAllDay ? 1 : 0),\(task.completed ? 1 : 0),\(stepStamp)"
        }
        basis += "|avail=\(context.tasksAvailable ? 1 : 0),\(context.calendarAuthorized ? 1 : 0),\(context.truncated ? 1 : 0)"
        basis += "|say=\(situation)"
        let hash = SHA256.hash(data: Data(basis.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 解析（§10.4 严格模式）

    /// 剥离首尾 code fence 后严格解码；必填字段缺失直接报错。
    nonisolated static func parse(_ raw: String) throws -> HoloTodayReliefAIResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // ```json ... ``` 或 ``` ... ```
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8) else {
            throw HoloTodayReliefError.invalidModelOutput("notUTF8")
        }
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(HoloTodayReliefAIResponse.self, from: data) else {
            throw HoloTodayReliefError.invalidModelOutput("jsonDecodeFailed")
        }
        guard response.schemaVersion == 1 else {
            throw HoloTodayReliefError.invalidModelOutput("unsupportedSchema(\(response.schemaVersion))")
        }
        guard ["proposal", "clarification", "cannotHelp"].contains(response.kind) else {
            throw HoloTodayReliefError.invalidModelOutput("unknownKind(\(response.kind))")
        }
        return response
    }

    /// 响应 → 候选（本地校验：requestID/scope/指纹、任务存在、步骤归属、互斥）。
    /// 模型输出的步骤版本/指纹不信任，一律用本地冻结事实补齐（§10.3）。
    nonisolated static func materialize(
        response: HoloTodayReliefAIResponse,
        context: HoloTodayReliefSessionContext,
        requestID: String,
        fingerprint: String
    ) throws -> ReliefGenerationOutcome {
        if let echo = response.requestID, echo != requestID {
            throw HoloTodayReliefError.invalidModelOutput("requestIDMismatch")
        }
        if response.kind == "clarification" {
            guard let question = response.question, !question.isEmpty else {
                throw HoloTodayReliefError.invalidModelOutput("clarificationWithoutQuestion")
            }
            return .clarification(
                question: question,
                suggestedAnswers: response.suggestedAnswers ?? []
            )
        }
        if response.kind == "cannotHelp" {
            return .cannotHelp(message: response.message ?? String(localized: "这次没整理成功，可以先手动安排。"))
        }

        // proposal
        let knownTasks = context.baseTasks.reduce(into: [UUID: HoloTodayReliefDisplayFacts.TaskDisplay]()) {
            $0[$1.taskID] = $1
        }
        let selections = response.selected ?? []
        var entries: [HoloTodaySelectionEntry] = []
        for selection in selections {
            guard let display = knownTasks[selection.taskID] else {
                // 未知任务 ID：本地拒绝，不能修修剪剪后继续采用（R31）
                throw HoloTodayReliefError.unknownReference("task:\(selection.taskID.uuidString)")
            }
            switch selection.goal.kind {
            case "taskResult":
                entries.append(HoloTodaySelectionEntry(taskID: selection.taskID, goal: .taskResult))
            case "existingStep":
                guard let stepID = selection.goal.stepID else {
                    throw HoloTodayReliefError.invalidModelOutput("existingStepWithoutID")
                }
                guard let displayStepID = display.currentStepID, displayStepID == stepID else {
                    throw HoloTodayReliefError.unknownReference("step:\(stepID.uuidString)")
                }
                entries.append(HoloTodaySelectionEntry(taskID: selection.taskID, goal: .existingStep(
                    stepID: stepID,
                    originRevisionID: display.currentStepRevisionID ?? UUID(),
                    contentFingerprint: display.currentStepFingerprint ?? ""
                )))
            default:
                throw HoloTodayReliefError.invalidModelOutput("unknownGoalKind(\(selection.goal.kind))")
            }
        }
        // 已选项被模型漏掉又没有明确放下 → 视为不完整建议，补回（§10.4）
        if let payload = context.currentPlanPayload, payload.selectionMode == .explicit {
            let selectedByAI = Set(entries.map(\.taskID))
            let deferredByAI = Set(response.deferredTaskIDs ?? [])
            for existing in payload.entries where !selectedByAI.contains(existing.taskID) && !deferredByAI.contains(existing.taskID) {
                if let display = knownTasks[existing.taskID], !display.completed {
                    entries.append(existing)
                }
            }
        }

        let deferred = response.deferredTaskIDs ?? []
        let overlap = Set(entries.map(\.taskID)).intersection(deferred)
        guard overlap.isEmpty else {
            throw HoloTodayReliefError.invalidModelOutput("selectedDeferredOverlap")
        }

        // 空库创建：仅真空库 + 用户明确单一动作（客户端复核；服务端 Prompt 同约束）
        var newTaskTitle: String? = nil
        if let newTask = response.newTask {
            let emptyLibrary = context.baseTasks.isEmpty && context.currentPlanPayload?.selectionMode != .explicit
            guard emptyLibrary else {
                throw HoloTodayReliefError.invalidModelOutput("newTaskOnNonEmptyLibrary")
            }
            guard entries.isEmpty, deferred.isEmpty else {
                throw HoloTodayReliefError.invalidModelOutput("newTaskWithSelection")
            }
            newTaskTitle = String(newTask.title.prefix(100))
        }

        let payload = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: entries,
            deferredTaskIDs: deferred,
            confirmedMustTaskIDs: [],
            deadlineAcknowledgements: []   // 确认只来自用户行内操作，模型不得生成（§10.4）
        )
        let candidate = HoloTodayReliefCandidate(
            scope: context.scope,
            sourceFingerprint: fingerprint,
            payload: payload,
            newTaskTitle: newTaskTitle,
            expectedHeads: context.currentPlanHeads,
            displayFacts: HoloTodayReliefDisplayFacts(
                tasks: knownTasks,
                constraints: context.constraints,
                truncated: context.truncated,
                tasksAvailable: context.tasksAvailable,
                calendarAuthorized: context.calendarAuthorized
            )
        )
        return .proposal(candidate)
    }
}

// MARK: - JSONEncoder ISO8601 便利

nonisolated private extension JSONEncoder {
    static func dateEncodingStrategyCustomISO8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

// MARK: - 生产兜底

/// 默认 Provider 不支持 today_relief_plan purpose 时（理论不可达），明确报错不静默。
@MainActor
private struct UnavailableTodayReliefService: HoloTodayReliefModelServicing {
    func sendTodayReliefPlan(bodyJSON: String, usageActionId: String) async throws -> String {
        throw HoloTodayReliefError.network("当前 Provider 不支持 today_relief_plan purpose")
    }
}

// MARK: - 会话上下文工厂（Today 弹层与 HoloAI 聊天共用同一候选/校验/采用链）

@MainActor
enum HoloTodayReliefSessionFactory {

    /// 冻结当前会话事实：当前计划 + 基础候选（今日到期/逾期/无日期近任务）+ 可用性。
    /// 候选上限 40（§10.1：模型首版最多 40 个任务）；截断明示 truncated。
    static func makeContext(situation: String? = nil) async -> HoloTodayReliefSessionContext {
        await CoreDataStack.shared.waitUntilReady()
        let scope = HoloTodayDayScope.current()
        let repository = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext)
        let planRead = repository.currentPlan(scope: scope)

        var taskIDs = Set<UUID>()
        var currentPayload: HoloTodayPlanPayload?
        var heads: [UUID] = []
        if case .active(let payload, let headIDs) = planRead.state {
            currentPayload = payload
            heads = headIDs
            taskIDs.formUnion(payload.entries.map(\.taskID))
            taskIDs.formUnion(payload.deferredTaskIDs)
        }
        let todoRepo = TodoRepository.shared
        let baseTasks = todoRepo.getDueTodayTasks() + todoRepo.getOverdueTasks() + todoRepo.getUnplannedOpenTasks(limit: 10)
        var seen = Set<UUID>()
        for task in DuplicateRowFilter.deduplicatingCopies(baseTasks) {
            guard seen.insert(task.id).inserted else { continue }
            taskIDs.insert(task.id)
        }
        let facts = repository.facts(taskIDs: taskIDs, stepIDs: [])
        let execution = HoloTaskExecutionRepository(context: CoreDataStack.shared.viewContext)

        var matterLookup: [UUID: String] = [:]
        if HoloMatterRolloutPolicy.storageEnabled {
            for matter in HoloMatterRepository.shared.matters(lifecycles: [.active]).prefix(20) {
                for link in HoloMatterRepository.shared.links(matterID: matter.id) where link.entityType == .todoTask {
                    if let id = UUID(uuidString: link.entityID), taskIDs.contains(id) {
                        matterLookup[id] = matter.title
                    }
                }
            }
        }

        var displays: [HoloTodayReliefDisplayFacts.TaskDisplay] = []
        for id in taskIDs {
            guard let task = facts.tasks[id], task.visible, !task.completed else { continue }
            let step = execution.steps(taskID: id).first {
                $0.deletedAt == nil && $0.kind == .action && $0.state != .done
            }
            var stepFingerprint: String? = nil
            if let step {
                let fact = HoloTodayReliefPolicy.StepFact(
                    id: step.id, taskID: step.taskID,
                    actionText: step.actionText, doneWhen: step.doneWhen,
                    stateRaw: step.stateRaw, originRevisionID: step.originRevisionID
                )
                stepFingerprint = HoloTodayReliefPolicy.stepFingerprint(fact)
            }
            let isOverdue = TodoTaskDatePolicy.isOverdue(
                dueDate: task.dueDate, isAllDay: task.isAllDay, completed: false
            )
            displays.append(HoloTodayReliefDisplayFacts.TaskDisplay(
                taskID: id,
                title: task.title,
                dueAt: task.dueDate,
                isAllDay: task.isAllDay,
                isOverdue: isOverdue,
                matterTitle: matterLookup[id],
                currentStepID: step?.id,
                currentStepAction: step?.actionText,
                currentStepFingerprint: stepFingerprint,
                currentStepRevisionID: step?.originRevisionID,
                hasSteps: execution.activeRevision(taskID: id) != nil,
                completed: task.completed
            ))
        }
        displays.sort { lhs, rhs in
            (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
        }
        return HoloTodayReliefSessionContext(
            scope: scope,
            baseTasks: Array(displays.prefix(40)),
            constraints: [],
            currentPlanPayload: currentPayload,
            currentPlanHeads: heads,
            truncated: displays.count > 40,
            tasksAvailable: true,
            calendarAuthorized: ScheduleStore.shared.authorizationStatus == .fullAccess,
            situation: situation
        )
    }
}
