//
//  HoloTodayReliefModels.swift
//  Holo
//
//  「今天减负」纯值契约（2026-10-03 实施方案 §7）
//
//  - HoloTodayDayScope：冻结的当日范围（左闭右开），scopeKey = dateKey@timeZone；
//  - HoloTodayPlanPayload：当日计划完整版本载荷（canonical JSON + SHA256 摘要）；
//  - 候选/回执/错误：服务与 UI 之间的类型化边界，不持有 NSManagedObject；
//  - 日计划只决定注意力选择与当日目标，不携带任务标题等展示数据（UI 读真实对象）。
//

import Foundation
import CryptoKit

// MARK: - 当日范围（§7.1）

nonisolated struct HoloTodayDayScope: Equatable, Sendable {
    /// Gregorian 当地日期 `YYYY-MM-DD`。
    let dateKey: String
    let timeZoneIdentifier: String
    /// 当日边界（左闭右开）：[dayStart, dayEnd)。
    let dayStart: Date
    let dayEnd: Date

    /// `dateKey@timeZoneIdentifier`。
    var scopeKey: String { dateKey + "@" + timeZoneIdentifier }

    /// 用冻结的日历与参考时刻构造；不得用固定 86400 秒推下一天。
    init(referenceTime: Date, calendar: Calendar, timeZone: TimeZone) {
        var scoped = calendar
        scoped.timeZone = timeZone
        let start = scoped.startOfDay(for: referenceTime)
        let end = scoped.date(byAdding: .day, value: 1, to: start) ?? start

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone

        self.dateKey = formatter.string(from: referenceTime)
        self.timeZoneIdentifier = timeZone.identifier
        self.dayStart = start
        self.dayEnd = end
    }

    /// 当前时刻的 scope（采用前的过期检查用；读取路径应传冻结值）。
    static func current(now: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current) -> HoloTodayDayScope {
        HoloTodayDayScope(referenceTime: now, calendar: calendar, timeZone: timeZone)
    }

    /// referenceTime 是否仍落在本 scope 内（跨午夜/时区变化 → false）。
    func contains(_ referenceTime: Date) -> Bool {
        dayStart <= referenceTime && referenceTime < dayEnd
    }
}

// MARK: - 计划载荷（§7.2）

nonisolated enum HoloTodaySelectionMode: String, Codable, Sendable {
    /// 未启用显式计划：继续基础 Today 读取规则。
    case inheritBase
    /// 用户显式选择（entries 允许为空 = 今天不主动推进任何任务）。
    case explicit
}

/// 当日推进目标：整件事，或引用真实已有步骤（不复制内容，完成事实读执行仓库）。
nonisolated enum HoloTodayGoal: Equatable, Sendable {
    case taskResult
    case existingStep(stepID: UUID, originRevisionID: UUID, contentFingerprint: String)

    var isTaskResult: Bool {
        if case .taskResult = self { return true }
        return false
    }
}

nonisolated struct HoloTodaySelectionEntry: Codable, Equatable, Sendable {
    let taskID: UUID
    let goal: HoloTodayGoal
}

/// 放下今日到期/逾期任务的风险确认：绑定任务 ID + 实际期限指纹（当日范围即生效范围）。
nonisolated struct HoloTodayDeadlineAcknowledgement: Codable, Equatable, Sendable {
    let taskID: UUID
    let deadlineFingerprint: String
}

nonisolated struct HoloTodayPlanPayload: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    /// 首版 entries 上限：超过时拒绝写入并提示手动减少，不静默截断。
    static let maxEntries = 50

    let schemaVersion: Int
    let selectionMode: HoloTodaySelectionMode
    /// 顺序即推进顺序（由数组表达，不另存 order 字段）。
    let entries: [HoloTodaySelectionEntry]
    /// 本次/当日明确放下的任务（不包含所有未选任务）。
    let deferredTaskIDs: [UUID]
    /// 用户明确标记「今天必须做」的任务（模型推测不得写入）。
    let confirmedMustTaskIDs: [UUID]
    let deadlineAcknowledgements: [HoloTodayDeadlineAcknowledgement]

    init(
        schemaVersion: Int = HoloTodayPlanPayload.schemaVersion,
        selectionMode: HoloTodaySelectionMode,
        entries: [HoloTodaySelectionEntry] = [],
        deferredTaskIDs: [UUID] = [],
        confirmedMustTaskIDs: [UUID] = [],
        deadlineAcknowledgements: [HoloTodayDeadlineAcknowledgement] = []
    ) {
        self.schemaVersion = schemaVersion
        self.selectionMode = selectionMode
        self.entries = entries
        self.deferredTaskIDs = deferredTaskIDs
        self.confirmedMustTaskIDs = confirmedMustTaskIDs
        self.deadlineAcknowledgements = deadlineAcknowledgements
    }

    /// inheritBase 合法形态：显式选择相关集合必须全空（§7.2）。
    static let inheritBase = HoloTodayPlanPayload(selectionMode: .inheritBase)

    // MARK: Canonical JSON / 摘要

    nonisolated enum PayloadCodableError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    /// canonical 编码（sortedKeys）：摘要与幂等比较的唯一字节形态。
    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> HoloTodayPlanPayload {
        let decoder = JSONDecoder()
        let payload = try decoder.decode(HoloTodayPlanPayload.self, from: data)
        guard payload.schemaVersion == schemaVersion else {
            throw PayloadCodableError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }

    /// SHA256 摘要（hex 小写），用于 payloadDigest 与幂等去重。
    func digest() throws -> String {
        let hash = SHA256.hash(data: try canonicalData())
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 查询

    func entry(for taskID: UUID) -> HoloTodaySelectionEntry? {
        entries.first { $0.taskID == taskID }
    }

    func isDeferred(_ taskID: UUID) -> Bool {
        deferredTaskIDs.contains(taskID)
    }

    /// 追加/替换一条选择（保持其余顺序）。
    func withEntry(_ entry: HoloTodaySelectionEntry) -> HoloTodayPlanPayload {
        var next = entries.filter { $0.taskID != entry.taskID }
        next.append(entry)
        return HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: next,
            deferredTaskIDs: deferredTaskIDs.filter { $0 != entry.taskID },
            confirmedMustTaskIDs: confirmedMustTaskIDs,
            deadlineAcknowledgements: deadlineAcknowledgements
        )
    }

    /// 移出选择、放入放下（期限确认按需补记）。
    func deferring(taskID: UUID, acknowledgement: HoloTodayDeadlineAcknowledgement?) -> HoloTodayPlanPayload {
        var acks = deadlineAcknowledgements.filter { $0.taskID != taskID }
        if let acknowledgement { acks.append(acknowledgement) }
        return HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: entries.filter { $0.taskID != taskID },
            deferredTaskIDs: deferredTaskIDs.filter { $0 != taskID } + [taskID],
            confirmedMustTaskIDs: confirmedMustTaskIDs.filter { $0 != taskID },
            deadlineAcknowledgements: acks
        )
    }

    func removing(taskID: UUID) -> HoloTodayPlanPayload {
        HoloTodayPlanPayload(
            selectionMode: selectionMode,
            entries: entries.filter { $0.taskID != taskID },
            deferredTaskIDs: deferredTaskIDs.filter { $0 != taskID },
            confirmedMustTaskIDs: confirmedMustTaskIDs.filter { $0 != taskID },
            deadlineAcknowledgements: deadlineAcknowledgements
        )
    }
}

// MARK: - HoloTodayGoal 编码（与 AI 输出契约同形：{"kind":"taskResult"|"existingStep",...}）

extension HoloTodayGoal: Codable {
    nonisolated private enum CodingKeys: String, CodingKey {
        case kind, stepID, originRevisionID, contentFingerprint
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "taskResult":
            self = .taskResult
        case "existingStep":
            self = .existingStep(
                stepID: try container.decode(UUID.self, forKey: .stepID),
                originRevisionID: try container.decode(UUID.self, forKey: .originRevisionID),
                contentFingerprint: try container.decode(String.self, forKey: .contentFingerprint)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "未知 goal kind: \(kind)"
            )
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .taskResult:
            try container.encode("taskResult", forKey: .kind)
        case .existingStep(let stepID, let originRevisionID, let contentFingerprint):
            try container.encode("existingStep", forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
            try container.encode(originRevisionID, forKey: .originRevisionID)
            try container.encode(contentFingerprint, forKey: .contentFingerprint)
        }
    }
}

// MARK: - 读取状态（§8.4）

nonisolated struct HoloTodayPlanRead: Equatable, Sendable {
    nonisolated enum State: Equatable, Sendable {
        /// 本 scope 从未采用过显式计划：继续基础 Today 行为。
        case noPlan
        /// 单一 head、payload 可读、引用到齐。
        case active(payload: HoloTodayPlanPayload, headRevisionIDs: [UUID])
        /// 多个真正分叉的 heads：显示「两台设备的今日安排不同，选择一次」。
        case conflict(candidates: [HoloTodayPlanConflictCandidate])
        /// 引用（父版本/任务/步骤）尚未到齐：不发布假空态、不回退基础列表。
        case syncing(reason: String)
        /// 读到未知 schema / 非法 payload / 相同 operationID 不同 digest。
        case unavailable(reason: String)
    }

    let scope: HoloTodayDayScope
    let state: State
}

/// 分叉候选：一个 head 的完整版本（供用户选择一份）。
nonisolated struct HoloTodayPlanConflictCandidate: Equatable, Sendable {
    let revisionID: UUID
    let payload: HoloTodayPlanPayload
    let createdAt: Date
    let command: String
}

// MARK: - 候选与回执

/// 审阅后提交采用的候选（AI 或手动审阅产出）。
nonisolated struct HoloTodayPlanCandidate: Equatable, Sendable {
    let scope: HoloTodayDayScope
    /// 冻结输入的指纹（来源变化 → staleSource；手动路径由载荷校验覆盖时可传空串跳过）。
    let sourceFingerprint: String
    /// 建议 payload（用户未编辑时直接采用）。
    let payload: HoloTodayPlanPayload
    /// 空库创建的根任务标题（用户已确认、可编辑）；非空时必须真空库。
    let newTaskTitle: String?
}

nonisolated struct HoloTodayPlanReceipt: Equatable, Sendable {
    /// 本次命令落库的版本；unchanged 时为当前 head（无 head 时为 nil）。
    let revisionID: UUID?
    /// 命中相同 operationID+digest 的重放（不重复建对象）。
    let replayed: Bool
    /// 是否真正写入了新版本（false = 无变化，未写版本）。
    let changed: Bool
    let changedTaskIDs: [UUID]
    /// 空库创建的根任务 ID（如有）。
    let createdTaskID: UUID?
    /// 操作后的 head payload。
    let payload: HoloTodayPlanPayload
}

// MARK: - 命令与错误

nonisolated enum HoloTodayPlanCommand: String {
    case adopt
    case manualAdd = "manualAdd"
    case manualDefer = "manualDefer"
    case manualGoal = "manualGoal"
    case undo
    case reset
    case resolveConflict = "resolveConflict"
}

nonisolated enum HoloTodayPlanError: Error, Equatable, Sendable {
    /// 冻结的输入指纹与当前事实不一致（审阅期间来源变化）。
    case staleSource(String)
    /// 采用时已跨午夜/换时区：本 scope 不再接受写入。
    case expiredDay(String)
    /// 引用无效：任务不存在/不可见/已完成、步骤不属于该任务或已失效、entries 超上限等。
    case invalidTarget(String)
    /// 放下今日到期/逾期任务但缺少有效风险确认（或期限指纹已变）。
    case acknowledgementRequired(UUID)
    /// heads 与预期不一致（并发编辑/分叉未解决）/同 operationID 不同 digest。
    case conflict(String)
    /// store 未就绪或持久化数据不可读（未知 schema 等）。
    case unavailable(String)
    case saveFailed(String)
}

// MARK: - 通知

nonisolated extension Notification.Name {
    /// 日计划写入成功后的唯一广播（Today/Widget 据此刷新；载荷无敏感内容）。
    static let holoTodayPlanDidChange = Notification.Name("holoTodayPlanDidChange")
}
