//
//  GoalWorkshopCoordinator.swift
//  Holo
//
//  目标共创编排器（方案任务 4）
//
//  - 对外：start / reply / skip / choose / generatePlan / cancel
//  - 会话状态唯一真源是 GoalWorkshopStore；协调器只做「取态→发请求→校验→落库」
//  - 每会话模型请求预算（GoalWorkshopBudget）是防滥用保险丝：失败的请求当场退款，
//    只有真正推进流程的成功轮次才消耗，会话不会因失败而卡死
//  - 429/断网/取消保留会话可恢复；非法模型输出做一次受控重试（不占预算）；仍失败保留会话并抛可展示错误
//  - 业务写入（保存目标）只由确认页的提交服务处理，本类零业务落库
//
//  ⚠️ 产品决策（东林 2026-09-19 拍板）：「一起想清楚」不占用户对话额度，免费用户全量开放。
//  依据：共创由用户主动创建，每会话请求有预算保险丝兜底，成本可控；后端 goal_workshop
//  同步改为不记入 chat 额度池（quotaTypeForPurpose 返回 nil，仅保留路由级限流兜量）。
//  因此本类不做任何额度预检，历史上基于 quotas["chat"] 的闸门已随该决策移除。
//

import Foundation

enum GoalWorkshopCoordinatorError: Error, Equatable {
    /// 429/限流终态（服务繁忙或限流兜底触发）：会话已保存，稍后可续
    case quotaExhaustedMidFlow
    /// 会话不存在（被放弃/删除/损坏）
    case sessionUnavailable(UUID)
    /// 同会话已有在途请求（重复点击）
    case duplicateInFlight(UUID)
    /// 模型输出两轮（含一次重试）仍未通过校验；会话保留，lastModelFailureText 已记录，已耗预算已退款
    case invalidModelOutput(String)
    /// 会话模型请求预算（保险丝）耗尽
    case requestBudgetExhausted

    var isRecoverableByWaiting: Bool {
        self == .quotaExhaustedMidFlow
    }
}

/// 模型服务窄接口：生产=HoloBackendAIProvider(goal_workshop purpose 非流式)；测试=假实现
protocol GoalWorkshopModelServicing {
    func sendGoalWorkshop(_ bodyJSON: String) async throws -> String
}

@MainActor
final class GoalWorkshopCoordinator {

    private let service: GoalWorkshopModelServicing
    private let store: GoalWorkshopStore
    /// 会话在途请求（防同轮重复提交；返回时清理）
    private var inFlight: Set<UUID> = []

    init(service: GoalWorkshopModelServicing,
         store: GoalWorkshopStore = .shared) {
        self.service = service
        self.store = store
    }

    // MARK: - 对外操作

    /// 开始新会话并发起首轮 understand（不占对话额度，见文件头产品决策）
    func start(seedText: String, goalID: UUID? = nil,
               contextRefs: [GoalWorkshopContextRef] = []) async throws -> GoalWorkshopSessionV1 {
        var session = GoalWorkshopSessionV1(goalID: goalID, originalText: seedText)
        try store.saveIfRevisionMatches(session)
        return try await advance(session: session, operation: .understand, input: seedText,
                                 skippedQuestion: false, contextRefs: contextRefs)
    }

    /// 用户回答当前问题
    func reply(sessionID: UUID, text: String) async throws -> GoalWorkshopSessionV1 {
        var session = try load(sessionID)
        try session.applyUserReply(text)
        try store.saveIfRevisionMatches(session)
        return try await advance(session: session, operation: .understand, input: text,
                                 skippedQuestion: false, contextRefs: [])
    }

    /// 跳过：understanding 改问路径；exploring 接受推荐（纯状态迁移，不发请求）
    func skip(sessionID: UUID) async throws -> GoalWorkshopSessionV1 {
        var session = try load(sessionID)
        try session.skipQuestion()
        try store.saveIfRevisionMatches(session)
        return session
    }

    /// 选择路径（纯状态迁移，不发请求）
    func choose(sessionID: UUID, optionID: String) async throws -> GoalWorkshopSessionV1 {
        var session = try load(sessionID)
        try session.choose(routeID: optionID)
        try store.saveIfRevisionMatches(session)
        return session
    }

    /// 按已选路径生成草案
    func generatePlan(sessionID: UUID,
                      contextRefs: [GoalWorkshopContextRef] = []) async throws -> GoalWorkshopSessionV1 {
        let session = try load(sessionID)
        return try await advance(session: session, operation: .buildPlan, input: nil,
                                 skippedQuestion: false, contextRefs: contextRefs)
    }

    /// 跳过追问直接要路径（questioningSkipped 后由 UI 调用）
    func requestOptions(sessionID: UUID) async throws -> GoalWorkshopSessionV1 {
        let session = try load(sessionID)
        return try await advance(session: session, operation: .proposeOptions, input: nil,
                                 skippedQuestion: true, contextRefs: [])
    }

    /// 纠正既有事实：撤回旧条目（留痕）并追加用户陈述；下一轮请求快照随之更新
    func correctFact(sessionID: UUID, factID: String, text: String) async throws -> GoalWorkshopSessionV1 {
        var session = try load(sessionID)
        try session.correctFact(id: factID, with: text)
        try store.saveIfRevisionMatches(session)
        return session
    }

    /// 放弃会话
    func cancel(sessionID: UUID) async throws {
        var session = try load(sessionID)
        try session.abandon()
        try store.saveIfRevisionMatches(session)
        try store.discard(id: sessionID)
    }

    func loadSession(_ sessionID: UUID) throws -> GoalWorkshopSessionV1 {
        try load(sessionID)
    }

    // MARK: - 核心推进

    private func advance(session: GoalWorkshopSessionV1,
                         operation: GoalWorkshopRequestV1.Operation,
                         input: String?,
                         skippedQuestion: Bool,
                         contextRefs: [GoalWorkshopContextRef]) async throws -> GoalWorkshopSessionV1 {
        guard !inFlight.contains(session.id) else {
            throw GoalWorkshopCoordinatorError.duplicateInFlight(session.id)
        }

        inFlight.insert(session.id)
        defer { inFlight.remove(session.id) }

        // 预算消耗即状态：先落库再按新 revision 构建请求体（模型须回显该值）
        var budgeted = session
        do {
            try budgeted.beginModelRequest()
        } catch {
            throw GoalWorkshopCoordinatorError.requestBudgetExhausted
        }
        try store.saveIfRevisionMatches(budgeted)

        let body = GoalWorkshopPromptBuilder.requestBody(
            session: budgeted,
            operation: operation,
            input: input,
            skippedQuestion: skippedQuestion,
            contextRefs: contextRefs
        )

        do {
            let raw = try await service.sendGoalWorkshop(body)
            return try await applyResponse(raw, session: budgeted)
        } catch let error as GoalWorkshopCoordinatorError {
            // invalidModelOutput 的退款在 applyResponse 内完成（那里持有最新 revision）
            throw error
        } catch {
            // 网络失败/取消/429：会话与已答内容已在库，可恢复可续；没拿到结果就退预算
            refund(budgeted)
            throw mapTransportError(error)
        }
    }

    /// 预算退款：请求没成功就不占会话预算（产品决策见文件头）
    private func refund(_ session: GoalWorkshopSessionV1) {
        var refunded = session
        refunded.refundModelRequest()
        try? store.saveIfRevisionMatches(refunded)
    }

    /// 解码 + 校验 + 应用；非法输出做一次受控重试（同 revision 重发，不占流程预算）；
    /// 重试仍失败则退款并抛可展示错误，会话保留
    private func applyResponse(_ raw: String, session: GoalWorkshopSessionV1) async throws -> GoalWorkshopSessionV1 {
        var working = session
        do {
            return try decodeValidateApply(raw, session: working)
        } catch {
            working.recordModelFailure(String(describing: error))
            try? store.saveIfRevisionMatches(working)

            let retried = (try? await service.sendGoalWorkshop(
                GoalWorkshopPromptBuilder.requestBody(
                    session: working,
                    operation: operationForRetry(session: working),
                    input: nil,
                    skippedQuestion: false,
                    contextRefs: []
                )
            )) ?? ""
            do {
                return try decodeValidateApply(retried, session: working)
            } catch {
                working.recordModelFailure(String(describing: error))
                working.refundModelRequest()
                try? store.saveIfRevisionMatches(working)
                throw GoalWorkshopCoordinatorError.invalidModelOutput(String(describing: error))
            }
        }
    }

    private func decodeValidateApply(_ raw: String, session: GoalWorkshopSessionV1) throws -> GoalWorkshopSessionV1 {
        let json = GoalWorkshopPromptBuilder.extractResponseBody(raw)
        guard let data = json.data(using: .utf8) else {
            throw GoalWorkshopCoordinatorError.invalidModelOutput("响应非 UTF-8 文本")
        }
        let response = try JSONDecoder().decode(GoalWorkshopResponseV1.self, from: data)
        var updated = session
        // 迟到/重复响应在 apply 内被 revision 守卫丢弃
        try updated.apply(response)
        try store.saveIfRevisionMatches(updated)
        return updated
    }

    /// 重试按会话当前阶段选操作（重试不带新一轮用户输入）
    private func operationForRetry(session: GoalWorkshopSessionV1) -> GoalWorkshopRequestV1.Operation {
        switch session.phase {
        case .understanding where session.questioningSkipped: return .proposeOptions
        case .understanding: return .understand
        case .exploring: return .proposeOptions
        case .choosing, .reviewing: return .buildPlan
        case .saved, .abandoned: return .understand
        }
    }

    private func mapTransportError(_ error: Error) -> Error {
        // 429/限流 → 可等待恢复；其余网络错误原样抛（调用方区分取消）。
        // 额度已随 2026-09-19 产品决策豁免，这里只剩服务繁忙/限流兜底语义。
        let nsError = error as NSError
        if nsError.code == 429 || (nsError.userInfo["status"] as? Int) == 429 {
            return GoalWorkshopCoordinatorError.quotaExhaustedMidFlow
        }
        return error
    }

    private func load(_ sessionID: UUID) throws -> GoalWorkshopSessionV1 {
        guard let session = try store.load(id: sessionID) else {
            throw GoalWorkshopCoordinatorError.sessionUnavailable(sessionID)
        }
        return session
    }
}
