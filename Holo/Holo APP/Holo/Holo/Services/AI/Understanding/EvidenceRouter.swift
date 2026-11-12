//
//  EvidenceRouter.swift
//  Holo
//
//  理解引擎 M2.3：本机取证路由（07-M2施工图）。
//
//  模型只输出受控 EvidenceRequest，路由按能力目录分派到本机实现；
//  失败返回具体类型（capabilityUnavailable 等），不降级为空数组当「没有反例」。
//

import Foundation

/// 取证请求（受控形状；字段必须来自能力目录声明）。
nonisolated struct EvidenceRequest: Equatable, Sendable {
    var op: EvidenceOp
    var domain: ObservationDomain
    var concepts: [String] = []
    var sourceRefs: [String] = []
    var baselineWindow: DateInterval?
    var currentWindow: DateInterval?
    var limit: Int = 10
}

/// 归属查证汇总：证据分层列出，结论不越证据（proxy 证据占主导时才判 proxy）。
nonisolated struct OwnershipSummary: Equatable, Sendable {
    var selfEvidenced: [String]     // 本人证据 sourceRef（self 归属/用户原话）
    var proxyEvidenced: [String]    // 明确代办证据
    var unknown: [String]
    var verdict: String             // self | proxy | mixed | unknown
}

/// 频次比较（财务域样板实现：同概念两窗口计数——M1.1「六个月三次猫粮」同款口径）。
nonisolated struct PeriodComparison: Equatable, Sendable {
    var concept: String
    var baselineCount: Int
    var currentCount: Int
    var baselineDays: Int
    var currentDays: Int
    /// 方向由程序判定，阈值口径留给策略层（effectBand 由本机比较规则产生）。
    var direction: String           // up | down | flat
}

nonisolated struct EvidencePayload: Equatable, Sendable {
    var relatedObservations: [LifeObservation]?
    var ownership: OwnershipSummary?
    var comparison: PeriodComparison?
}

/// 取证失败类型（工程稿 §3.3：查询失败返回具体失败类型）。
nonisolated enum EvidenceFailure: Error, Equatable, Sendable {
    case capabilityUnavailable(domain: ObservationDomain, op: EvidenceOp)
    case insufficientEvidence(reason: String)
    case invalidRequest(reason: String)
}

nonisolated struct EvidenceResult: Equatable, Sendable {
    var request: EvidenceRequest
    var payload: EvidencePayload?
    var failure: EvidenceFailure?

    static func failed(_ request: EvidenceRequest, _ failure: EvidenceFailure) -> EvidenceResult {
        EvidenceResult(request: request, payload: nil, failure: failure)
    }
}

/// 路由器：能力目录判定 → 域内实现。纯索引查询，无网络无模型。
nonisolated struct EvidenceRouter {
    var index: ObservationIndex
    var capabilityLookup: (ObservationDomain) -> DomainCapability? = { DomainCapabilityCatalog.capability(for: $0) }

    func execute(_ request: EvidenceRequest) -> EvidenceResult {
        guard let capability = capabilityLookup(request.domain) else {
            return .failed(request, .capabilityUnavailable(domain: request.domain, op: request.op))
        }
        guard capability.supports(request.op) else {
            return .failed(request, .capabilityUnavailable(domain: request.domain, op: request.op))
        }
        switch request.op {
        case .retrieveRelated:
            let related = retrieveRelated(request)
            if related.isEmpty {
                return .failed(request, .insufficientEvidence(reason: "无同概念观察（未查到≠无反例，此处只是无材料）"))
            }
            return EvidenceResult(request: request,
                payload: EvidencePayload(relatedObservations: related, ownership: nil, comparison: nil),
                failure: nil)
        case .checkOwnership:
            let summary = checkOwnership(request)
            return EvidenceResult(request: request,
                payload: EvidencePayload(relatedObservations: nil, ownership: summary, comparison: nil),
                failure: nil)
        case .comparePeriods:
            guard let baseline = request.baselineWindow, let current = request.currentWindow,
                  let concept = request.concepts.first else {
                return .failed(request, .invalidRequest(reason: "频次比较需要 baseline/current 窗口与概念"))
            }
            let comparison = comparePeriods(concept: concept, baseline: baseline, current: current)
            return EvidenceResult(request: request,
                payload: EvidencePayload(relatedObservations: nil, ownership: nil, comparison: comparison),
                failure: nil)
        case .compareConditions, .alignEvents, .searchCounterEvidence, .checkCoverage:
            return .failed(request, .capabilityUnavailable(domain: request.domain, op: request.op))
        }
    }

    // MARK: - retrieveRelated：概念交集召回（跨域——同主题材料天然跨 finance/task/thought；
    // 排除 AI 派生：派生内容不作独立证据）。

    func retrieveRelated(_ request: EvidenceRequest) -> [LifeObservation] {
        let wanted = Set(request.concepts)
        guard !wanted.isEmpty else { return [] }
        return index.observations.values
            .filter { obs in
                !Set(obs.concepts).isDisjoint(with: wanted) && obs.businessState != .derived
            }
            .sorted { $0.occurredAt ?? $0.recordedAt < $1.occurredAt ?? $1.recordedAt }
            .prefix(request.limit)
            .map { $0 }
    }

    // MARK: - checkOwnership：归属证据分层汇总。

    func checkOwnership(_ request: EvidenceRequest) -> OwnershipSummary {
        var summary = OwnershipSummary(selfEvidenced: [], proxyEvidenced: [], unknown: [], verdict: "unknown")
        for ref in request.sourceRefs {
            guard let obs = index.observations.values.first(where: { $0.sourceRef == ref }) else { continue }
            switch obs.attribution {
            case .self_: summary.selfEvidenced.append(ref)
            case .proxy: summary.proxyEvidenced.append(ref)
            case .thirdParty, .unknown:
                if obs.businessState == .quote { summary.selfEvidenced.append(ref) } else { summary.unknown.append(ref) }
            }
        }
        if !summary.proxyEvidenced.isEmpty && summary.selfEvidenced.isEmpty {
            summary.verdict = "proxy"
        } else if !summary.selfEvidenced.isEmpty && summary.proxyEvidenced.isEmpty {
            summary.verdict = "self"
        } else if !summary.selfEvidenced.isEmpty {
            summary.verdict = "mixed"
        }
        return summary
    }

    // MARK: - comparePeriods：同概念两窗口频次（程序计算，模型不得改值）。

    func comparePeriods(concept: String, baseline: DateInterval, current: DateInterval) -> PeriodComparison {
        func count(in window: DateInterval) -> Int {
            index.observations.values.filter { obs in
                guard obs.concepts.contains(concept), let at = obs.occurredAt else { return false }
                return window.contains(at)
            }.count
        }
        let baselineCount = count(in: baseline)
        let currentCount = count(in: current)
        // 窗口天数含头含尾（8-01 00:00 ~ 8-31 23:59 = 31 天，向下取整会丢尾日）。
        let baselineDays = max(1, Int((baseline.duration / 86_400).rounded(.up)))
        let currentDays = max(1, Int((current.duration / 86_400).rounded(.up)))
        let baselineRate = Double(baselineCount) / Double(baselineDays)
        let currentRate = Double(currentCount) / Double(currentDays)
        let direction = currentRate > baselineRate * 1.2 ? "up"
            : currentRate < baselineRate * 0.8 ? "down" : "flat"
        return PeriodComparison(concept: concept, baselineCount: baselineCount, currentCount: currentCount,
                                baselineDays: baselineDays, currentDays: currentDays, direction: direction)
    }
}
