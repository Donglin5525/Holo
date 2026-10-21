//
//  GoalPlanContract.swift
//  Holo
//
//  目标闭环·计划契约（2026-10-20 最终规格 §6.1 / §6.2 / §6.4 / §6.5）
//
//  本文件只定义值类型与纯函数，不触碰 Core Data：
//  - GoalPlanPayloadV2：生效计划快照（存入 GoalPlanRevisionMO.planPayloadJSON）
//  - 绑定/来源/回顾/资金期次/预算规则
//  - GoalAdjustmentDraftV2：修正草案（白名单操作，禁止任意字段 patch）
//  - HoloAgentGoalScope：目标分析范围（请求→快照→结果全链透传）
//  - GoalFundScheduleMath：资金期次确定性演算（R26/R27）
//  - 旧版（DecisionSummaryV1 / 手动目标）兼容解码
//

import Foundation
import CryptoKit

// MARK: - 结果来源

/// 结果来源类型；与 GoalMetricSource 同义，但独立定义以免 UI 枚举顺序绑死契约
enum GoalResultSourceKind: String, Codable, Equatable, Sendable {
    case manual
    case habit
    case ledger
}

/// 财务范围（§6.2）：老目标空值按 wholeLedgerDelta 解释，不静默切账户余额
enum GoalLedgerScopeKind: String, Codable, Equatable, Sendable {
    case wholeLedgerDelta = "whole_ledger_delta"
    case accountBalance = "account_balance"

    var displayName: String {
        switch self {
        case .wholeLedgerDelta: return String(localized: "全账本净结余增加")
        case .accountBalance: return String(localized: "单账户余额")
        }
    }
}

struct GoalLedgerScopePayload: Codable, Equatable, Sendable {
    var kind: GoalLedgerScopeKind
    /// kind == .accountBalance 时必填：单一真实资产账户
    var accountID: UUID?
}

/// 习惯来源聚合语义（§6.2）：体重 latest、练习时长 sum、限制按原始数量
enum GoalHabitAggregationKind: String, Codable, Equatable, Sendable {
    case sum
    case latest
    case windowTrend = "window_trend"
}

enum GoalResultComparison: String, Codable, Equatable, Sendable {
    case reach          // 达到目标值（>=）
    case stayBelow      // 不超过目标值（<=）
    case trendDown      // 向下趋势（减重）
    case trendUp
}

struct GoalPlanResultSourceV2: Codable, Equatable, Sendable {
    var sourceType: GoalResultSourceKind
    /// habit → 数值习惯 id；ledger+accountBalance → 账户 id；manual → nil
    var sourceID: UUID?
    var unit: String?
    var aggregation: GoalHabitAggregationKind?
    var comparison: GoalResultComparison?
    var targetValue: Double?
    var baselineValue: Double?
    var baselineObservedAt: Date?
    /// 结果观测超过多少天视为过期（stale）；nil = 不判过期
    var freshnessDays: Int?
    /// 仅 ledger 有意义；nil 按旧语义 wholeLedgerDelta
    var ledgerScope: GoalLedgerScopePayload?
    /// 用户尚未选定可靠来源（§4.1「待补齐」）
    var isPending: Bool = false

    var resolvedLedgerScope: GoalLedgerScopeKind {
        ledgerScope?.kind ?? .wholeLedgerDelta
    }
}

// MARK: - 绑定

enum GoalPlanBindingRole: String, Codable, Equatable, Sendable {
    case result
    case action
    case constraint
    case context
}

enum GoalPlanBindingEntityType: String, Codable, Equatable, Sendable {
    case task
    case habit
    case budget
    case account
    case fundSchedule = "fund_schedule"
}

struct GoalPlanBindingV2: Codable, Equatable, Identifiable, Sendable {
    /// bindingID：计划内稳定标识，跨版本沿用
    var id: UUID
    var entityType: GoalPlanBindingEntityType
    /// 真实对象 id；创建中对象先用 draftRef，提交成功后解析
    var entityID: UUID?
    var draftRef: String?
    var role: GoalPlanBindingRole
    var effectiveFrom: Date?
    /// nil = 跟随目标生命周期；阶段性要求到期后由代码结束绑定
    var effectiveThrough: Date?
    var displayTitle: String?
    /// 是否为本目标专属创建（false = 复用用户既有共享对象，只改绑定不改对象父引用）
    var isGoalOwned: Bool = true
    /// 绑定被结束的时间（结束 ≠ 删除对象）
    var endedAt: Date?
    /// 仅本目标的要求，不修改共享习惯的默认频次、单位或原记录。
    var requirement: GoalBindingRequirement?

    var isActive: Bool { endedAt == nil }

    func isEffective(at date: Date) -> Bool {
        guard isActive else { return false }
        if let effectiveFrom, date < effectiveFrom { return false }
        if let effectiveThrough, date >= effectiveThrough { return false }
        return true
    }

    /// 由既有对象 id 推导的稳定绑定 id：legacy 基线与 Goal.tasks/habits 合并去重时，
    /// 同一对象多次进入得到同一 bindingID（SHA256 前 16 字节，设置 UUID v4/variant 位）
    static func stableID(entityType: GoalPlanBindingEntityType, entityID: UUID) -> UUID {
        let seed = "holo.goal.binding|\(entityType.rawValue)|\(entityID.uuidString.lowercased())"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - 安排与限制

struct GoalFundInstallmentV2: Codable, Equatable, Sendable {
    var dueDate: Date
    var amount: Decimal
    var note: String?
}

struct GoalBudgetRuleV2: Codable, Equatable, Sendable {
    var bindingID: UUID
    var accountID: UUID
    var categoryID: UUID?
    var amount: Decimal
    /// BudgetPeriod.rawValue（week/month/year）
    var period: String
    var startDate: Date
    /// 复用既有预算而非新建；nil = 新建
    var reuseExistingBudgetID: UUID?
}

/// 限制型要求（如「每周奶茶 ≤ 2 杯」）：从原始数值另算，不改习惯模块通用完成规则（§3.2）
struct GoalConstraintRuleV2: Codable, Equatable, Sendable {
    var bindingID: UUID
    var habitID: UUID?
    var draftRef: String?
    var limitValue: Double
    var unit: String?
    /// 窗口天数（7 = 每周）
    var windowDays: Int
    var displayTitle: String?
}

// MARK: - 回顾

struct GoalPlanReviewV2: Codable, Equatable, Sendable {
    /// nil = 关闭定期回顾
    var cadenceDays: Int?
    var nextReviewAt: Date?
    var observationWindowDays: Int
    /// 调整后重点验证项
    var verificationFocus: [String]

    static let defaultCadenceDays = 7
    static let defaultObservationWindowDays = 14

    static func weeklyDefault(now: Date, calendar: Calendar = .current) -> GoalPlanReviewV2 {
        GoalPlanReviewV2(
            cadenceDays: defaultCadenceDays,
            nextReviewAt: calendar.date(byAdding: .day, value: defaultCadenceDays, to: now),
            observationWindowDays: defaultObservationWindowDays,
            verificationFocus: []
        )
    }
}

// MARK: - 用户原意与决策依据

struct GoalPlanIntentV2: Codable, Equatable, Sendable {
    var originalWish: String?
    var successCriteria: String?
    var deadline: Date?
}

enum GoalPlanOrigin: String, Codable, Equatable, Sendable {
    case workshop
    case planning
    case manual
    case legacy
    case adjustment
}

struct GoalPlanDecisionBasisV2: Codable, Equatable, Sendable {
    var origin: GoalPlanOrigin
    var sourceSessionID: UUID?
    var sourceReportMessageID: UUID?
    var confirmedAt: Date
    /// 用户在确认页选中的变更摘要（不复制报告正文）
    var selectedChangeSummaries: [String] = []
}

// MARK: - 生效计划 payload

struct GoalPlanPayloadV2: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int = GoalPlanPayloadV2.currentSchemaVersion
    var intent: GoalPlanIntentV2
    var resultSource: GoalPlanResultSourceV2?
    var bindings: [GoalPlanBindingV2]
    var fundSchedule: [GoalFundInstallmentV2] = []
    var budgetRule: GoalBudgetRuleV2?
    var constraints: [GoalConstraintRuleV2] = []
    var review: GoalPlanReviewV2?
    var basis: GoalPlanDecisionBasisV2

    /// 当前仍生效的绑定（未结束、按日期生效）
    func activeBindings(at date: Date) -> [GoalPlanBindingV2] {
        bindings.filter { $0.isEffective(at: date) }
    }

    func bindings(role: GoalPlanBindingRole, at date: Date) -> [GoalPlanBindingV2] {
        activeBindings(at: date).filter { $0.role == role }
    }

    func binding(id: UUID) -> GoalPlanBindingV2? {
        bindings.first { $0.id == id }
    }
}

// MARK: - payload 信封解码（旧版兼容）

enum GoalPlanPayloadDecodeResult: Equatable, Sendable {
    case current(GoalPlanPayloadV2)
    /// 首版共创决策摘要（无类型化绑定），由调用方生成 legacy 基线
    case legacyDecisionSummary
    /// 未来 schema：提示不可编辑，不能当空计划覆盖（§9.4）
    case unsupportedFuture(version: Int)
    case empty
    case corrupted
}

enum GoalPlanPayloadCodec {
    private struct VersionProbe: Decodable { let schemaVersion: Int? }

    /// 写入带毫秒的 ISO8601；读取兼容带/不带毫秒（旧串）
    nonisolated static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "非 ISO8601 日期：\(text)")
        }
        return decoder
    }

    static func encode(_ payload: GoalPlanPayloadV2) throws -> String {
        var payload = payload
        if payload.bindings.contains(where: { $0.requirement != nil }) { payload.schemaVersion = 3 }
        let data = try makeEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GoalPlanContractError.encodingFailed
        }
        return text
    }

    static func decode(_ json: String?) -> GoalPlanPayloadDecodeResult {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return .empty }
        let decoder = makeDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return .corrupted }
        let version = probe.schemaVersion ?? 1
        if version > GoalPlanPayloadV2.currentSchemaVersion {
            return .unsupportedFuture(version: version)
        }
        if version < 2 {
            return .legacyDecisionSummary
        }
        guard let payload = try? decoder.decode(GoalPlanPayloadV2.self, from: data) else { return .corrupted }
        return .current(payload)
    }
}

enum GoalPlanContractError: Error, Equatable {
    case encodingFailed
    case invalidOperation(String)
}

// MARK: - 修正草案（§6.5）

enum GoalAdjustmentOperationKind: String, Codable, Equatable, CaseIterable, Sendable {
    case createTask = "create_task"
    case reuseTask = "reuse_task"
    case updateTask = "update_task"
    case createHabit = "create_habit"
    case reuseHabit = "reuse_habit"
    case updateHabit = "update_habit"
    case createBudget = "create_budget"
    case updateBudget = "update_budget"
    case endBinding = "end_binding"
    case replaceBinding = "replace_binding"
    case updateFundSchedule = "update_fund_schedule"
    case updateReview = "update_review"
    /// 必须单独明确确认（§3.4 / R28）
    case changeSuccessCriteria = "change_success_criteria"

    /// 改成果标准/总额/期限需要独立确认
    var requiresSeparateConfirmation: Bool {
        self == .changeSuccessCriteria
    }

    var isCreation: Bool {
        switch self {
        case .createTask, .createHabit, .createBudget: return true
        default: return false
        }
    }
}

struct GoalAdjustmentTaskSpecV2: Codable, Equatable, Sendable {
    var title: String
    var dueDate: Date?
    var plannedStart: Date?
    var plannedEnd: Date?
    var priority: Int?
    var note: String?
}

struct GoalAdjustmentHabitSpecV2: Codable, Equatable, Sendable {
    var name: String
    /// HabitFrequency.rawValue
    var frequency: String
    var targetCount: Int?
    /// "checkIn" / "numeric"
    var type: String
    var unit: String?
    var targetValue: Double?
    var isBadHabit: Bool?
    var aggregation: GoalHabitAggregationKind?
    /// 限制型（如奶茶上限）
    var constraintLimit: Double?
    var constraintWindowDays: Int?
}

struct GoalAdjustmentCriteriaChangeV2: Codable, Equatable, Sendable {
    var newSuccessCriteria: String?
    var newTargetValue: Double?
    var newDeadline: Date?
    var reason: String?
}

struct GoalAdjustmentOperationV2: Codable, Equatable, Identifiable, Sendable {
    /// 操作稳定 id（模型给出或代码生成）；用于逐项取消/编辑对账
    var id: String
    var kind: GoalAdjustmentOperationKind
    /// 用户在差异单中是否选中（默认选中；取消后不提交）
    var isSelected: Bool = true
    /// reuse/update/end 的目标对象或绑定 id；必须在候选白名单内
    var targetEntityID: UUID?
    var targetBindingID: UUID?
    /// 新建对象的草案引用，提交后解析为真实 id
    var draftRef: String?
    var role: GoalPlanBindingRole?
    var taskSpec: GoalAdjustmentTaskSpecV2?
    var habitSpec: GoalAdjustmentHabitSpecV2?
    var budgetRule: GoalBudgetRuleV2?
    var fundSchedule: [GoalFundInstallmentV2]?
    var review: GoalPlanReviewV2?
    var criteriaChange: GoalAdjustmentCriteriaChangeV2?
    /// 当前安排 → 建议安排的可读摘要（差异单展示）
    var currentSummary: String?
    var proposedSummary: String?
    var reason: String?
    var appliesFrom: Date?
    var appliesThrough: Date?
    var affectedObjectTitle: String?

    /// 白名单校验：kind 与携带 payload 必须匹配，禁止任意字段 patch
    func validateShape() throws {
        switch kind {
        case .createTask:
            guard taskSpec != nil, draftRef != nil else { throw GoalPlanContractError.invalidOperation("create_task 需要 taskSpec 与 draftRef") }
        case .reuseTask, .reuseHabit:
            guard targetEntityID != nil else { throw GoalPlanContractError.invalidOperation("\(kind.rawValue) 需要 targetEntityID") }
        case .updateTask:
            guard targetEntityID != nil, taskSpec != nil else { throw GoalPlanContractError.invalidOperation("update_task 需要 targetEntityID 与 taskSpec") }
        case .createHabit:
            guard habitSpec != nil, draftRef != nil else { throw GoalPlanContractError.invalidOperation("create_habit 需要 habitSpec 与 draftRef") }
        case .updateHabit:
            guard targetEntityID != nil, habitSpec != nil else { throw GoalPlanContractError.invalidOperation("update_habit 需要 targetEntityID 与 habitSpec") }
        case .createBudget, .updateBudget:
            guard budgetRule != nil else { throw GoalPlanContractError.invalidOperation("\(kind.rawValue) 需要 budgetRule") }
        case .endBinding:
            guard targetBindingID != nil else { throw GoalPlanContractError.invalidOperation("end_binding 需要 targetBindingID") }
        case .replaceBinding:
            guard targetBindingID != nil, (draftRef != nil || targetEntityID != nil) else {
                throw GoalPlanContractError.invalidOperation("replace_binding 需要 targetBindingID 与替代对象")
            }
        case .updateFundSchedule:
            guard let fundSchedule, !fundSchedule.isEmpty else { throw GoalPlanContractError.invalidOperation("update_fund_schedule 需要期次") }
        case .updateReview:
            guard review != nil else { throw GoalPlanContractError.invalidOperation("update_review 需要 review") }
        case .changeSuccessCriteria:
            guard criteriaChange != nil else { throw GoalPlanContractError.invalidOperation("change_success_criteria 需要 criteriaChange") }
        }
    }
}

struct GoalAdjustmentDraftV2: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultValidity: TimeInterval = 7 * 24 * 60 * 60

    var schemaVersion: Int = GoalAdjustmentDraftV2.currentSchemaVersion
    var draftID: UUID
    var goalID: UUID
    var baseRevisionID: UUID
    var sourceReportMessageID: UUID?
    var sourceDigest: String
    var createdAt: Date
    var expiresAt: Date
    var operations: [GoalAdjustmentOperationV2]
    var expectedObservation: String?

    var id: UUID { draftID }

    func isExpired(at date: Date) -> Bool { date >= expiresAt }

    var selectedOperations: [GoalAdjustmentOperationV2] { operations.filter(\.isSelected) }

    var containsSeparateConfirmationChanges: Bool {
        selectedOperations.contains { $0.kind.requiresSeparateConfirmation }
    }
}

// MARK: - 目标分析范围（§6.4）

struct HoloAgentGoalScope: Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = HoloAgentGoalScope.currentSchemaVersion
    var goalID: UUID
    var planRevisionID: UUID
    var reviewID: UUID
    var windowStart: Date
    var windowEndExclusive: Date
    var snapshotCutoffAt: Date
    var timeZoneID: String
    var sourceDigest: String

    /// 去重键：同目标+同计划版本+标准化窗口+同依据 → 同一份报告（§5）
    var dedupeKey: String {
        let formatter = HoloAgentGoalScope.wireDateFormatter
        return [
            goalID.uuidString,
            planRevisionID.uuidString,
            formatter.string(from: windowStart),
            formatter.string(from: windowEndExclusive),
            sourceDigest,
        ].joined(separator: "|")
    }

    nonisolated static let wireDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension HoloAgentGoalScope: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, goalID, planRevisionID, reviewID
        case windowStart, windowEndExclusive, snapshotCutoffAt, timeZoneID, sourceDigest
    }

    /// 线上 JSON 用 ISO8601 字符串（与规格示例一致）；兼容数值秒
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? HoloAgentGoalScope.currentSchemaVersion
        goalID = try c.decode(UUID.self, forKey: .goalID)
        planRevisionID = try c.decode(UUID.self, forKey: .planRevisionID)
        reviewID = try c.decode(UUID.self, forKey: .reviewID)
        windowStart = try Self.decodeDate(c, .windowStart)
        windowEndExclusive = try Self.decodeDate(c, .windowEndExclusive)
        snapshotCutoffAt = try Self.decodeDate(c, .snapshotCutoffAt)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        sourceDigest = try c.decode(String.self, forKey: .sourceDigest)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(goalID, forKey: .goalID)
        try c.encode(planRevisionID, forKey: .planRevisionID)
        try c.encode(reviewID, forKey: .reviewID)
        let f = HoloAgentGoalScope.wireDateFormatter
        try c.encode(f.string(from: windowStart), forKey: .windowStart)
        try c.encode(f.string(from: windowEndExclusive), forKey: .windowEndExclusive)
        try c.encode(f.string(from: snapshotCutoffAt), forKey: .snapshotCutoffAt)
        try c.encode(timeZoneID, forKey: .timeZoneID)
        try c.encode(sourceDigest, forKey: .sourceDigest)
    }

    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        if let text = try? c.decode(String.self, forKey: key) {
            if let date = wireDateFormatter.date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "非 ISO8601 日期：\(text)")
        }
        let seconds = try c.decode(Double.self, forKey: key)
        // 与后端 taskRange 同口径：≥1e11 视为毫秒
        return Date(timeIntervalSince1970: seconds >= 1e11 ? seconds / 1000 : seconds)
    }
}

// MARK: - 资金期次演算（§4.1 / R26 / R27）

enum GoalFundScheduleMath {

    enum Status: String, Codable, Equatable, Sendable {
        case achieved
        case onTrack = "on_track"
        case behind
        case ahead
        case deadlinePassed = "deadline_passed"
        case noRemainingInstallments = "no_remaining_installments"
    }

    struct Outcome: Codable, Equatable, Sendable {
        var status: Status
        /// 截止 cutoff 应已存入（已过期次之和）
        var plannedToDate: Decimal
        /// plannedToDate - currentFunds；正数 = 落后
        var shortfallToDate: Decimal
        var remainingAmount: Decimal
        var remainingInstallments: [GoalFundInstallmentV2]
        /// 剩余每期应存；无剩余期次 / 已达成 / 已过截止时为 nil（不除零、不重分配过去期次）
        var suggestedPerInstallment: Decimal?
    }

    /// - Parameters:
    ///   - cutoff: 快照截止时点；dueDate < cutoff 视为已过期次
    ///   - deadline: 资金截止日；cutoff ≥ deadline 视为已过截止
    static func evaluate(target: Decimal,
                         currentFunds: Decimal,
                         schedule: [GoalFundInstallmentV2],
                         cutoff: Date,
                         deadline: Date?) -> Outcome {
        let sorted = schedule.sorted { $0.dueDate < $1.dueDate }
        let past = sorted.filter { $0.dueDate < cutoff }
        let future = sorted.filter { $0.dueDate >= cutoff }
        let plannedToDate = past.reduce(Decimal(0)) { $0 + $1.amount }
        let shortfall = plannedToDate - currentFunds
        let remainingAmount = max(target - currentFunds, 0)

        if currentFunds >= target {
            return Outcome(status: .achieved,
                           plannedToDate: plannedToDate,
                           shortfallToDate: shortfall,
                           remainingAmount: 0,
                           remainingInstallments: future,
                           suggestedPerInstallment: nil)
        }
        if let deadline, cutoff >= deadline {
            return Outcome(status: .deadlinePassed,
                           plannedToDate: plannedToDate,
                           shortfallToDate: shortfall,
                           remainingAmount: remainingAmount,
                           remainingInstallments: [],
                           suggestedPerInstallment: nil)
        }
        guard !future.isEmpty else {
            return Outcome(status: .noRemainingInstallments,
                           plannedToDate: plannedToDate,
                           shortfallToDate: shortfall,
                           remainingAmount: remainingAmount,
                           remainingInstallments: [],
                           suggestedPerInstallment: nil)
        }
        let perInstallment = roundedMoney(remainingAmount / Decimal(future.count))
        let status: Status
        if shortfall > 0 {
            status = .behind
        } else if shortfall < 0 {
            status = .ahead
        } else {
            status = .onTrack
        }
        return Outcome(status: status,
                       plannedToDate: plannedToDate,
                       shortfallToDate: shortfall,
                       remainingAmount: remainingAmount,
                       remainingInstallments: future,
                       suggestedPerInstallment: perInstallment)
    }

    /// 可行性提示（§4.1）：新安排比既有均值高多少、预计释放后仍差多少
    struct Feasibility: Codable, Equatable, Sendable {
        var historicalAverage: Decimal?
        var increaseOverHistory: Decimal?
        var uncoveredAfterRelief: Decimal?
    }

    static func feasibility(suggestedPerInstallment: Decimal?,
                            historicalContributions: [Decimal],
                            expectedReliefPerInstallment: Decimal?) -> Feasibility {
        guard let suggestedPerInstallment else { return Feasibility() }
        let average: Decimal? = historicalContributions.isEmpty
            ? nil
            : roundedMoney(historicalContributions.reduce(Decimal(0), +) / Decimal(historicalContributions.count))
        let increase = average.map { suggestedPerInstallment - $0 }
        var uncovered: Decimal?
        if let increase, increase > 0 {
            let relief = expectedReliefPerInstallment ?? 0
            uncovered = max(increase - relief, 0)
        }
        return Feasibility(historicalAverage: average,
                           increaseOverHistory: increase,
                           uncoveredAfterRelief: uncovered)
    }

    static func roundedMoney(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .plain)
        return result
    }
}

// MARK: - 时间窗口（§6.2）：[start, min(endExclusive, cutoff))

struct GoalObservationWindow: Equatable, Sendable {
    var start: Date
    var endExclusive: Date
    var cutoff: Date
    var timeZone: TimeZone

    /// 历史事实查询用的实际上界
    var effectiveEndExclusive: Date { min(endExclusive, cutoff) }

    func contains(_ date: Date) -> Bool {
        date >= start && date < effectiveEndExclusive
    }

    /// 以用户时区日边界构造最近 N 天窗口（含今天至 cutoff）
    static func trailingDays(_ days: Int, cutoff: Date, timeZone: TimeZone = .current) -> GoalObservationWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: cutoff)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: todayStart) ?? todayStart
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? cutoff
        return GoalObservationWindow(start: start, endExclusive: endExclusive, cutoff: cutoff, timeZone: timeZone)
    }
}

// MARK: - 目标局部要求（schema 3）

enum GoalRequirementMetric: String, Codable, CaseIterable, Sendable {
    case recordedDays, eventCount, sum, latest, taskCompletion
    var title: String {
        switch self {
        case .recordedDays: return "有记录天数"
        case .eventCount: return "活动次数"
        case .sum: return "数值累计"
        case .latest: return "最新测量"
        case .taskCompletion: return "原任务完成"
        }
    }
}

struct GoalBindingRequirement: Codable, Equatable, Sendable {
    var metric: GoalRequirementMetric
    var target: Double
    var comparison: GoalResultComparison = .reach
    var windowDays: Int = 7
    var calendarMonth: Bool = false
    /// 使用已结束归属日，避免尚未结束的夜被判断为失败。
    var closedDaysOnly: Bool = false
}

enum GoalRequirementState: String, Codable, Sendable { case met, unmet, observing, missing, unavailable }

struct GoalRequirementObservation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var entityID: UUID?
    var entityType: GoalPlanBindingEntityType
    var role: GoalPlanBindingRole
    var requirement: GoalBindingRequirement
    var value: Double?
    var unit: String
    var windowStart: Date
    var windowEndExclusive: Date
    var confirmedDays: Int
    var expectedDays: Int
    var state: GoalRequirementState
    var sourceDigest: String
    var recordNotBefore: Date? = nil

    var valueText: String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.maximumFractionDigits = 2
        return value.map { "\(formatter.string(from: NSNumber(value: $0)) ?? "") / \(formatter.string(from: NSNumber(value: requirement.target)) ?? "") \(unit)" } ?? "待记录"
    }
    var stateText: String {
        switch state {
        case .met: return "已达到本项约定"
        case .unmet: return requirement.comparison == .stayBelow ? "已超约定" : "继续积累"
        case .observing: return "进行中，完整情况待确认"
        case .missing: return "尚无记录"
        case .unavailable: return "来源暂不可用"
        }
    }
}
