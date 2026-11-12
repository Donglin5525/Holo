//
//  ShadowRuntime.swift
//  Holo
//
//  理解引擎 M2.5：影子运行时状态机（07-M2施工图）。
//
//  影子期产出只进本地台账，不写正式记忆、不进对话上下文。
//  状态机三件硬约束：
//  ① 迁移只走合法边（防跳级/回跳）；
//  ② 滞留超时降级（P1-5：中间态停留超时限回炉 newEvidence，防僵尸候选堆积）；
//  ③ 终态不可逆（采用/拒绝后不再被旧请求推动——「应用结果前再查版本」的本地前哨）。
//

import Foundation

/// 影子候选阶段（工程稿 §5.3 状态机的本地子集；影子期无云端在途态拆分）。
nonisolated enum ShadowStage: String, Codable, Sendable, Equatable {
    case newEvidence            // 新证据待打包
    case packaged               // 已组主题包，待提案
    case proposing              // 提案生成中（含等模型返回）
    case awaitingLocalEvidence  // 提案已出，等本机取证
    case verifying              // 核验中（含三闸判定）
    // 终态
    case adoptable              // 核验通过可进入评审视野（影子期不自动采用）
    case observing              // 仅内部观察
    case askWhenRelevant        // 相关场景可补问
    case rejected               // 拒绝（含措辞/强度闸拦截）
    case invalidated            // 来源/授权/用户控制变化失效

    var isTerminal: Bool {
        switch self {
        case .adoptable, .observing, .askWhenRelevant, .rejected, .invalidated: return true
        default: return false
        }
    }
}

/// 合法迁移表：key=当前阶段，value=允许进入的阶段。未列出的迁移一律拒绝。
nonisolated enum ShadowTransitions {
    static let allowed: [ShadowStage: [ShadowStage]] = [
        .newEvidence: [.packaged, .invalidated],
        .packaged: [.proposing, .invalidated],
        .proposing: [.awaitingLocalEvidence, .rejected, .invalidated],   // 提不出可查证候选→rejected
        .awaitingLocalEvidence: [.verifying, .newEvidence, .invalidated],// 取证不可得→回炉等新证据
        .verifying: [.adoptable, .observing, .askWhenRelevant, .rejected, .invalidated],
    ]

    static func canTransition(from: ShadowStage, to: ShadowStage) -> Bool {
        if from.isTerminal { return false }                 // 终态不可逆
        return allowed[from]?.contains(to) == true
    }
}

/// 一条影子候选的台账条目。
nonisolated struct ShadowCandidate: Codable, Sendable, Equatable {
    var id: String              // 主题 key + 证据指纹派生（同主题新证据=新身份）
    var themeKey: String
    var stage: ShadowStage
    var enteredStageAt: Date
    var attempts: Int = 0       // 本阶段重试次数（回炉累计）
    var lastReason: String?

    init(id: String, themeKey: String, now: Date) {
        self.id = id
        self.themeKey = themeKey
        self.stage = .newEvidence
        self.enteredStageAt = now
    }
}

/// 中间态滞留时限（P1-5）：超时回炉 newEvidence，等证据实质变化重新打包。
nonisolated enum ShadowPolicy {
    static let stageTimeout: TimeInterval = 72 * 3600
    /// 回炉次数上限：同一候选反复回炉说明证据永远凑不齐，转 rejected 留诊断。
    static let maxRequeues: Int = 3
}

/// 影子台账（本地 JSON 持久化，独立于正式记忆存储）。
nonisolated struct ShadowLedger: Codable, Sendable, Equatable {
    private(set) var candidates: [String: ShadowCandidate]

    init() { candidates = [:] }

    // MARK: - 迁移

    /// 阶段推进：非法迁移返回 nil（调用方不得静默重试——显式失败暴露问题）。
    @discardableResult
    mutating func advance(id: String, to stage: ShadowStage, now: Date, reason: String? = nil) -> ShadowCandidate? {
        guard var candidate = candidates[id] else { return nil }
        guard ShadowTransitions.canTransition(from: candidate.stage, to: stage) else { return nil }
        if stage == .newEvidence { candidate.attempts += 1 }   // 回炉计数
        candidate.stage = stage
        candidate.enteredStageAt = now
        candidate.lastReason = reason
        candidates[id] = candidate
        return candidate
    }

    /// 登记新候选（同 id 已存在且非终态=重复登记，拒绝防僵尸覆盖）。
    @discardableResult
    mutating func register(id: String, themeKey: String, now: Date) -> ShadowCandidate? {
        if let existing = candidates[id], !existing.stage.isTerminal { return nil }
        let fresh = ShadowCandidate(id: id, themeKey: themeKey, now: now)
        candidates[id] = fresh
        return fresh
    }

    // MARK: - 滞留超时降级（P1-5）

    /// 中间态停留超时限：回炉 newEvidence；回炉次数达上限转 rejected。
    /// 返回被处理的 id 列表（诊断用）。终态候选不动。
    @discardableResult
    mutating func evictStale(now: Date, timeout: TimeInterval = ShadowPolicy.stageTimeout) -> [String] {
        var touched: [String] = []
        for (id, candidate) in candidates where !candidate.stage.isTerminal {
            guard now.timeIntervalSince(candidate.enteredStageAt) > timeout else { continue }
            if candidate.attempts >= ShadowPolicy.maxRequeues {
                candidates[id]?.stage = .rejected
                candidates[id]?.enteredStageAt = now
                candidates[id]?.lastReason = "滞留超时且回炉\(candidate.attempts)次——证据长期凑不齐"
            } else {
                candidates[id]?.stage = .newEvidence
                candidates[id]?.enteredStageAt = now
                candidates[id]?.attempts = candidate.attempts + 1
                candidates[id]?.lastReason = "滞留超时回炉（等证据实质变化）"
            }
            touched.append(id)
        }
        return touched
    }

    // MARK: - 与核验闸集成（verifying → 终态）

    /// 核验后落终态：被拒→rejected（带闸理由）；通过→按闸结果分流。
    @discardableResult
    mutating func settle(id: String, gateResult: (accepted: Bool, action: String, reasons: [String]), now: Date) -> ShadowCandidate? {
        let stage: ShadowStage
        let reason: String?
        if !gateResult.accepted {
            stage = .rejected
            reason = gateResult.reasons.joined(separator: ";")
        } else {
            switch gateResult.action {
            case "adopt": stage = .adoptable; reason = nil
            case "ask": stage = .askWhenRelevant; reason = nil
            default:
                stage = .observing
                reason = gateResult.reasons.isEmpty ? nil : gateResult.reasons.joined(separator: ";")
            }
        }
        return advance(id: id, to: stage, now: now, reason: reason)
    }

    func snapshot(stage: ShadowStage? = nil) -> [ShadowCandidate] {
        candidates.values
            .filter { stage == nil || $0.stage == stage }
            .sorted { $0.id < $1.id }
    }

    // MARK: - 持久化（独立 JSON，不进 CloudKit、不进正式记忆存储）

    static func load(directory: URL) -> ShadowLedger {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("shadow-ledger.json")),
              let ledger = try? JSONDecoder().decode(ShadowLedger.self, from: data) else { return ShadowLedger() }
        return ledger
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("shadow-ledger.json"), options: .atomic)
    }
}
