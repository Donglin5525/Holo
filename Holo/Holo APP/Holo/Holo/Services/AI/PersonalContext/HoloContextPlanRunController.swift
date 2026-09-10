//
//  HoloContextPlanRunController.swift
//  Holo
//
//  个人情境规划运行状态的唯一写入者（实施方案 2026-09-09 §5.1/§6.3）：
//  - 阶段推进带 stageRevision 单调守卫与终态锁：终态后迟到回调不得改写；
//  - 每次迁移原子写回 ChatMessage.contextPlanRunJSON（页面销毁不等于任务消失）；
//  - 进程级存活登记表支撑重进/冷启动 reconcile：登记表之外的未终态运行一律
//    落明确失败，不残留「三个点」。
//
//  线程模型：阶段回调来自规划协调器的非隔离上下文，因此状态机用 NSLock 串行；
//  落库经由注入的 persist 闭包自行切回主线程（见 ChatViewModel 的装配）。
//

import Foundation

/// 进程内仍持有活跃任务的规划消息登记表。跨页面/跨 VM 判断「这条运行卡
/// 是否还有人在跑」的唯一依据；App 重启后为空，所有未终态运行都可判死。
final class HoloContextPlanRunRegistry: @unchecked Sendable {
    static let shared = HoloContextPlanRunRegistry()

    private let lock = NSLock()
    private var liveMessageIDs: Set<UUID> = []

    private init() {}

    func markLive(_ messageID: UUID) {
        lock.lock()
        liveMessageIDs.insert(messageID)
        lock.unlock()
    }

    func markDone(_ messageID: UUID) {
        lock.lock()
        liveMessageIDs.remove(messageID)
        lock.unlock()
    }

    func isLive(_ messageID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return liveMessageIDs.contains(messageID)
    }
}

/// 跨线程装配的运行控制器持有盒：回调线程写入、主线程读取，避免捕获变量并发变更。
final class HoloContextPlanRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HoloContextPlanRunController?

    var value: HoloContextPlanRunController? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ controller: HoloContextPlanRunController) {
        lock.lock()
        _value = controller
        lock.unlock()
    }
}

/// 单次规划运行的状态机外壳。所有状态迁移经此处守卫；持久化由 persist 闭包
/// 完成同步写（调用方保证其内部线程安全/主线程切换）。
final class HoloContextPlanRunController: @unchecked Sendable {

    private let lock = NSLock()
    private var _envelope: HoloContextPlanRunEnvelope
    private let messageID: UUID
    /// 原子落库闭包（仓库 updateContextPlanRun）。nil = 仅内存（测试用）。
    private let persist: ((UUID, String?) -> Void)?

    var envelope: HoloContextPlanRunEnvelope {
        lock.lock()
        defer { lock.unlock() }
        return _envelope
    }

    init(envelope: HoloContextPlanRunEnvelope, persist: ((UUID, String?) -> Void)? = nil) {
        self._envelope = envelope
        self.messageID = envelope.assistantMessageID
        self.persist = persist
        HoloContextPlanRunRegistry.shared.markLive(envelope.assistantMessageID)
    }

    deinit {
        HoloContextPlanRunRegistry.shared.markDone(messageID)
    }

    /// 阶段推进：revision 只能递增；终态一律拒绝（§5.1 迟到回调 guard）。
    /// 返回是否实际推进。
    @discardableResult
    func advance(
        to stage: HoloContextPlanStage,
        cloudTaskID: String? = nil,
        routeSource: HoloContextPlanRouteSource? = nil,
        routeReasonCode: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_envelope.stage.isTerminal else { return false }
        guard stage != _envelope.stage || cloudTaskID != nil else { return false }
        _envelope.stage = stage
        _envelope.stageRevision += 1
        _envelope.updatedAt = Date()
        if let cloudTaskID { _envelope.cloudTaskID = cloudTaskID; _envelope.canResume = true }
        if let routeSource { _envelope.routeSource = routeSource }
        if let routeReasonCode { _envelope.routeReasonCode = routeReasonCode }
        writeThroughLocked()
        return true
    }

    /// 终态：方案就绪。finalRunID 用于把临时 runID 换成草案真实 runID。
    func completeDraft(finalRunID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !_envelope.stage.isTerminal else { return }
        if let finalRunID, !finalRunID.isEmpty { _envelope.runID = finalRunID }
        _envelope.stage = .draftReady
        _envelope.stageRevision += 1
        _envelope.updatedAt = Date()
        _envelope.failureCode = nil
        writeThroughLocked()
        HoloContextPlanRunRegistry.shared.markDone(messageID)
    }

    /// 终态：失败（类型化错误码，§5.4）。
    @discardableResult
    func fail(code: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_envelope.stage.isTerminal else { return false }
        _envelope.stage = .failed
        _envelope.stageRevision += 1
        _envelope.updatedAt = Date()
        _envelope.failureCode = code
        _envelope.canResume = false
        writeThroughLocked()
        HoloContextPlanRunRegistry.shared.markDone(messageID)
        return true
    }

    /// 终态：用户取消。先持久化终态再取消底层任务（§6.3）。
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_envelope.stage.isTerminal else { return false }
        _envelope.stage = .cancelled
        _envelope.stageRevision += 1
        _envelope.updatedAt = Date()
        _envelope.canResume = false
        writeThroughLocked()
        HoloContextPlanRunRegistry.shared.markDone(messageID)
        return true
    }

    /// 仅在持锁时调用。
    private func writeThroughLocked() {
        guard let persist else { return }
        persist(messageID, Self.encode(_envelope))
    }

    // MARK: 编解码

    static func encode(_ envelope: HoloContextPlanRunEnvelope) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> HoloContextPlanRunEnvelope? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HoloContextPlanRunEnvelope.self, from: data)
    }

    // MARK: reconcile（§6.3）

    /// 重进/冷启动对账：把登记表之外的未终态运行落明确失败，杜绝永久三个点。
    static func interruptedRunIDs(from messages: [ChatMessageViewData]) -> [UUID] {
        messages
            .filter { $0.messageType == .contextPlan }
            .filter { $0.contextPlanJSON == nil }
            .compactMap { message -> UUID? in
                guard let envelope = decode(message.contextPlanRunJSON) else { return nil }
                guard !envelope.stage.isTerminal else { return nil }
                guard !HoloContextPlanRunRegistry.shared.isLive(message.id) else { return nil }
                return message.id
            }
    }

    /// 对账失败的统一终态载荷。
    static func interruptedEnvelope(for messageID: UUID, previous: HoloContextPlanRunEnvelope?) -> HoloContextPlanRunEnvelope {
        var envelope = previous ?? HoloContextPlanRunEnvelope(
            runID: messageID.uuidString,
            assistantMessageID: messageID,
            stage: .failed
        )
        envelope.stage = .failed
        envelope.stageRevision += 1
        envelope.updatedAt = Date()
        envelope.failureCode = "PLANNING_RUN_INTERRUPTED"
        envelope.canResume = false
        return envelope
    }
}
