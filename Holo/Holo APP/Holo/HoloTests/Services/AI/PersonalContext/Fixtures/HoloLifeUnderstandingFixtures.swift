//
//  HoloLifeUnderstandingFixtures.swift
//  HoloTests
//
//  「Holo 生活理解与 Matter 主动筹备」R0 冻结夹具（方案 2026-09-23 §2/§4.2 R0）。
//
//  本文件是主旅程 Q0—Q3 与四域模拟账号记录的唯一真相源；R1—R4 的测试与
//  评测从这里取数，不得在各自测试里另写一份字符串或记录。
//  纯数据 + 纯函数（仅 Foundation），可 standalone 编译。
//
//  纪律（方案 §2.1/§2.2）：
//  - 四域记录均须以正常业务入口或受控导入进入真实 Repository 后方可参与端到端；
//    本文件只定义「应该被写入什么」，R1 的接线测试负责证明真的写进去了。
//  - 不预建「我养猫」「摩卡是猫」等手工记忆；关系必须由原始记录进统一管道产生。
//  - 这些是模拟账号的测试记录，与任何真实用户数据无关。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
@testable import Holo
#endif

// MARK: - 冻结时钟与情境区间（方案 §2.1）

enum HoloLifeUnderstandingFrozenClock {
    /// 测试时钟：2026-09-23 12:00 Asia/Shanghai。
    static let referenceTimeString = "2026-09-23T12:00:00+08:00"

    static var referenceDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: referenceTimeString)!
    }

    static var timeZone: TimeZone { TimeZone(identifier: "Asia/Shanghai")! }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// 本地日起点（Asia/Shanghai 当日 00:00）。
    static func localDayStart(_ dateString: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return formatter.date(from: dateString)!
    }

    /// 主旅程旅行区间：2026-10-01 00:00 ≤ t < 2026-10-08 00:00（本地日半开区间，方案 §3.3）。
    /// 期间影响与安排覆盖一律以此区间为准，不得使用 now+30 天固定窗（R10）。
    static var travelInterval: (start: Date, end: Date) {
        (start: localDayStart("2026-10-01"), end: localDayStart("2026-10-08"))
    }
}

// MARK: - 主输入与对抗输入（方案 §2.2）

enum HoloLifeUnderstandingQueries {
    /// Q0 主输入：不含任何宠物词，也不含「护」「照」两个字（纯净性由 purityFailures 自动检查）。
    static let q0 = "我 10 月 1 日到 7 日去日本，第一次去，打算去东京和大阪。签证、机票、酒店都还没有安排，预算大约一万元。请帮我做好出发前的准备。"

    /// Q1 对抗输入：Q0 + 「护照已经办好」。「护照」只允许影响证件准备，
    /// 不得成为召回照护责任的原因（R1）。
    static let q1 = "我 10 月 1 日到 7 日去日本，第一次去，打算去东京和大阪。护照已经办好。签证、机票、酒店都还没有安排，预算大约一万元。请帮我做好出发前的准备。"

    /// Q2 空库对照与 Q3 反转对照使用同一 Q1 输入；差别在数据侧记录集（见 records(variant:)）。

    /// 宠物词面禁用表：Q0 不得含这些词；Q1 额外只允许「护照」一词出现（方案 §2.2 自动检查）。
    static let petLexiconTerms = ["猫", "摩卡", "宠物", "喂", "换水", "照护", "铲屎", "猫粮", "寄养"]

    /// 单字级禁用表：中文单字 token 切分下，这两个字是「护照/照护」误召回的根源（R1）。
    static let petLexiconCharacters: [Character] = ["护", "照"]

    /// 纯净性检查（绿断言；防止以后编辑用例重新引入词面线索）。
    /// 返回违例描述；空数组 = 通过。
    static func purityFailures() -> [String] {
        var failures: [String] = []
        for term in petLexiconTerms where q0.contains(term) {
            failures.append("Q0 含宠物词「\(term)」")
        }
        for character in petLexiconCharacters where q0.contains(character) {
            failures.append("Q0 含单字「\(character)」（护照/照护误召回根源）")
        }
        // Q1 是对抗输入，允许「护照」；但其余宠物词仍不得出现。
        let q1WithoutPassport = q1.replacingOccurrences(of: "护照", with: "")
        for term in petLexiconTerms where q1WithoutPassport.contains(term) {
            failures.append("Q1 在「护照」之外仍含宠物词「\(term)」")
        }
        return failures
    }

    /// 旅程 frame（R0 红测用：referenceTime 一律用冻结时钟；R3 起携带冻结情境区间）。
    static func travelFrame(
        utterance: String,
        timeRangeExpression: String,
        interval: (start: Date, end: Date)? = nil
    ) -> HoloPlanningRequestFrame {
        HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: "日本出行前的准备与安排",
            successConditions: ["出发前签证、机票、住宿与家中事务都有安排"],
            timeRangeExpression: timeRangeExpression,
            unknowns: [],
            retrievalDirections: ["离家期间的持续责任", "家中事务的既有安排"],
            referenceTime: HoloLifeUnderstandingFrozenClock.referenceDate,
            localTimeZone: "Asia/Shanghai",
            resolvedIntervalStart: interval?.start,
            resolvedIntervalEnd: interval?.end,
            trigger: "userRequest"
        )
    }
}

// MARK: - 四域模拟账号记录（方案 §2.1 表格冻结）

/// 一条模拟原始记录（语义合同；落库字段合同见 R0 报告 §3.8 对照）。
struct HoloLifeUnderstandingSourceRecord {
    /// 方案 §2.1 的 sourceKey：domain:entityID。
    let sourceKey: String
    /// finance / task / habit / thought。
    let domain: String
    /// transaction / todoTask / habitDefinition / habitCheckin / userNote。
    let sourceKind: String
    /// 获准的归一化正文（模拟「商品/备注」「任务标题」「想法正文」等真实业务字段）。
    let normalizedText: String
    /// 真实业务状态（域特定；缺失时保持未知，不得补成事实）。
    let businessState: [String: String]
    /// 事件发生时间（ISO8601）。
    let eventAt: String
    /// 记录落库时间（ISO8601；与事件时间刻意区分以覆盖补记）。
    let recordedAt: String
    /// 允许的推断上限（验收红线：超出即失败）。
    let allowedInference: String
    /// 独立血缘根 ID：同一真实事件派生的多条记录共用同根（A07 去重依据）。
    let lineageRootID: String
}

enum HoloLifeUnderstandingRecords {
    /// 记录集变体：Q0/Q1 全量；Q2 移除全部宠物照护来源；Q3 反转（代购/咖啡/引用他人）。
    enum Variant: String {
        case full            // Q0 / Q1
        case noPetSources    // Q2 空库对照
        case reversed        // Q3 反转对照
    }

    static func records(variant: Variant) -> [HoloLifeUnderstandingSourceRecord] {
        switch variant {
        case .full:
            return fullRecords
        case .noPetSources:
            // Q2：移除所有宠物照护原始记录，其余非照护记录可保留（证明系统不会无源推断）。
            return []
        case .reversed:
            return reversedRecords
        }
    }

    /// 全量记录（Q0/Q1）。模拟账号测试数据，非任何真实用户。
    static let fullRecords: [HoloLifeUnderstandingSourceRecord] = [
        // 财务：8 月 20 日买猫粮；商品/备注字段确实有「猫粮」。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "finance:tx-01",
            domain: "finance",
            sourceKind: "transaction",
            normalizedText: "猫粮 2kg（备注：家附近宠物店）",
            businessState: ["status": "valid", "duplicateImport": "false", "amount": "128.00"],
            eventAt: "2026-08-20T19:40:00+08:00",
            recordedAt: "2026-08-20T19:41:00+08:00",
            allowedInference: "宠物相关弱线索；独自不能证明所有权",
            lineageRootID: "evt-tx-20260820"
        ),
        // 待办：9 月 12 日任务「给摩卡换水」，已完成时间真实。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "task:task-01",
            domain: "task",
            sourceKind: "todoTask",
            normalizedText: "给摩卡换水",
            businessState: ["completed": "true", "completedAt": "2026-09-12T21:05:00+08:00"],
            eventAt: "2026-09-12T21:05:00+08:00",
            recordedAt: "2026-09-12T09:00:00+08:00",
            allowedInference: "至少有一次照料活动；不证明摩卡物种",
            lineageRootID: "evt-care-20260912"
        ),
        // 习惯定义：「给摩卡换水」。定义表达意图，打卡表达发生（两者分开）。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "habit:habit-01",
            domain: "habit",
            sourceKind: "habitDefinition",
            normalizedText: "给摩卡换水",
            businessState: ["frequency": "daily", "active": "true"],
            eventAt: "2026-09-10T08:00:00+08:00",
            recordedAt: "2026-09-10T08:00:00+08:00",
            allowedInference: "可能存在持续照料责任（定义本身不算发生）",
            lineageRootID: "evt-habitdef-20260910"
        ),
        // 习惯打卡：9/12 打卡与 task:task-01 同一真实事件派生（同根，A07 只算一证）。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "habit:habit-01#checkin-20260912",
            domain: "habit",
            sourceKind: "habitCheckin",
            normalizedText: "给摩卡换水（打卡）",
            businessState: ["checkinState": "done"],
            eventAt: "2026-09-12T21:05:00+08:00",
            recordedAt: "2026-09-12T21:06:00+08:00",
            allowedInference: "一次真实照料发生；与 task-01 同根不另计独立证据",
            lineageRootID: "evt-care-20260912"
        ),
        // 习惯打卡：9/15、9/16 独立事件（各自独立血缘）。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "habit:habit-01#checkin-20260915",
            domain: "habit",
            sourceKind: "habitCheckin",
            normalizedText: "给摩卡换水（打卡）",
            businessState: ["checkinState": "done"],
            eventAt: "2026-09-15T08:30:00+08:00",
            recordedAt: "2026-09-15T08:31:00+08:00",
            allowedInference: "一次真实照料发生",
            lineageRootID: "evt-care-20260915"
        ),
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "habit:habit-01#checkin-20260916",
            domain: "habit",
            sourceKind: "habitCheckin",
            normalizedText: "给摩卡换水（打卡）",
            businessState: ["checkinState": "done"],
            eventAt: "2026-09-16T08:20:00+08:00",
            recordedAt: "2026-09-16T08:21:00+08:00",
            allowedInference: "一次真实照料发生",
            lineageRootID: "evt-care-20260916"
        ),
        // 想法：用户本人陈述的历史经历，非引用他人。
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "thought:note-01",
            domain: "thought",
            sourceKind: "userNote",
            normalizedText: "上次出门找过人上门喂猫。",
            businessState: ["status": "active", "deleted": "false"],
            eventAt: "2026-05-02T22:10:00+08:00",
            recordedAt: "2026-05-02T22:10:00+08:00",
            allowedInference: "曾有离家时的猫咪照护安排；不代表本次已安排",
            lineageRootID: "evt-note-20260502"
        ),
    ]

    /// 反转记录（Q3）：交易是替朋友买、任务对象「摩卡」明确为咖啡、想法是引用朋友故事。
    static let reversedRecords: [HoloLifeUnderstandingSourceRecord] = [
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "finance:tx-01",
            domain: "finance",
            sourceKind: "transaction",
            normalizedText: "帮同事代购猫粮 2kg（备注：同事转账给我）",
            businessState: ["status": "valid", "duplicateImport": "false", "amount": "128.00"],
            eventAt: "2026-08-20T19:40:00+08:00",
            recordedAt: "2026-08-20T19:41:00+08:00",
            allowedInference: "代购不构成本人宠物相关证据",
            lineageRootID: "evt-tx-20260820"
        ),
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "task:task-01",
            domain: "task",
            sourceKind: "todoTask",
            normalizedText: "下单摩卡咖啡豆",
            businessState: ["completed": "true", "completedAt": "2026-09-12T21:05:00+08:00"],
            eventAt: "2026-09-12T21:05:00+08:00",
            recordedAt: "2026-09-12T09:00:00+08:00",
            allowedInference: "「摩卡」为咖啡；不构成宠物照料证据",
            lineageRootID: "evt-care-20260912"
        ),
        HoloLifeUnderstandingSourceRecord(
            sourceKey: "thought:note-01",
            domain: "thought",
            sourceKind: "userNote",
            normalizedText: "朋友说他上次出门找过人上门喂猫。",
            businessState: ["status": "active", "deleted": "false"],
            eventAt: "2026-05-02T22:10:00+08:00",
            recordedAt: "2026-05-02T22:10:00+08:00",
            allowedInference: "引用他人经历，不能变成用户事实",
            lineageRootID: "evt-note-20260502"
        ),
    ]

    /// 各变体的验收红线（与 JSON 评测夹具 forbiddenClaims 同义）。
    static func forbiddenClaims(variant: Variant) -> [String] {
        switch variant {
        case .full:
            return [
                "断言「你养猫」或「摩卡是猫」（身份未知）",
                "断言「你还没安排照护」（只能说「可访问记录中没有找到本次安排」）",
                "无证据生成个性化宠物任务",
            ]
        case .noPetSources:
            return [
                "说「你有宠物要照顾」",
                "生成任何个性化宠物任务或伪造 evidence/effect",
            ]
        case .reversed:
            return [
                "归属用户本人宠物照护责任",
                "把代购、引用他人经历当成用户事实",
            ]
        }
    }
}

// MARK: - 检索层候选工厂（R0 红测共用）

enum HoloLifeUnderstandingCandidateFactory {
    /// 最小可检索候选（adviceEligible；推断类需限定表达）。
    static func adviceCandidate(
        recordID: String,
        statement: String,
        conditionText: String? = nil,
        temporal: HoloContextTemporalV1? = nil,
        linkedContextIDs: [String] = [],
        epistemicStatus: HoloContextEpistemicStatus = .inferred
    ) -> HoloContextAdviceCandidate {
        HoloContextAdviceCandidate(
            recordID: recordID,
            versionID: "\(recordID)@v1",
            payload: HoloPersonalContextPayloadV1(
                contextID: "ctx-\(recordID)",
                statement: statement,
                relationText: statement,
                epistemicStatus: epistemicStatus,
                applicability: HoloContextApplicabilityV1(conditionText: conditionText),
                temporal: temporal,
                basis: [HoloContextBasisRef(sourceID: recordID, sourceRevision: "rev-1")],
                linkedContextIDs: linkedContextIDs,
                admission: HoloContextAdmissionV1(
                    level: .adviceEligible,
                    policyVersion: 1,
                    decidedAt: Date(timeIntervalSince1970: 0)
                )
            ),
            needsQualifiedExpression: epistemicStatus == .inferred
        )
    }
}
