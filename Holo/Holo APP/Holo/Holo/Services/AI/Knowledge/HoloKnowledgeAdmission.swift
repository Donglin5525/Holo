//
//  HoloKnowledgeAdmission.swift
//  Holo
//
//  统一准入（方案 v2.2 §3.2 统一问题 / §3.4 首发模板）
//
//  每个候选都要回答：原文是否支持？数据独立吗？观察跨度足够吗？搜过反例吗？
//  范围、时间、单位和缺失是否正确？未来有什么具体作用？是否仍适用且允许保存？
//  「数据是真的」与「这个归纳有用」分别判断。不以实体关键词兜底、不以固定
//  「出现 N 次」代替规律判断、不把模型数值置信度作为通行证。
//

import Foundation

nonisolated enum HoloKnowledgeAdmission {
    static let policyVersion = 1

    /// 近期一次性指令（「今晚简短一点」）与过去重要事件（「去年那次旅行」）的结构区分：
    /// 绝对窗口终点落在证据捕获时刻 ±2 天内且无适用条件 = 本次范围，不长期化。
    static let temporaryScopeToleranceSeconds: TimeInterval = 2 * 86_400

    static func assess(
        semantic: HoloKnowledgeSemantic,
        evidence: HoloKnowledgeEvidenceSnapshot,
        authorizedSourceDomains: Set<HoloMemoryDomain>
    ) -> HoloKnowledgeAdmissionVerdict {
        // 结构：主体、关系、正文缺一不可（真实输入边界）。
        guard !semantic.subjectRef.isEmpty,
              !semantic.relation.isEmpty,
              !semantic.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .reject(reason: .structureInvalid)
        }

        // 第三方：主体不是本人的命题不形成个人记忆（照料责任表达为本人需要考虑的条件）。
        guard semantic.subjectRef == "self" else {
            return .reject(reason: .thirdPartyNotAuthorized)
        }

        // 可追溯：任何保存都要有来源（用户原话也是来源）。
        guard !evidence.supportRefs.isEmpty else {
            return .reject(reason: .evidenceUntraceable)
        }

        // 来源授权：证据来源必须在授权范围内（发现三域 / 记忆八域不互相扩大）。
        let evidenceDomains = Set((evidence.supportRefs + evidence.counterRefs).map(\.sourceDomain))
        guard evidenceDomains.isSubset(of: authorizedSourceDomains) else {
            return .reject(reason: .sourceNotAuthorized)
        }

        // 禁止性推断：带医疗/心理/用药禁推的模型解释不作事实保存（对齐既有五路决策护栏）。
        if semantic.formation == .behavioralInference,
           semantic.prohibitedInferences.contains(where: {
               $0.hasPrefix("medical") || $0.hasPrefix("psychological") || $0.hasPrefix("medication")
           }) {
            return .reject(reason: .prohibitedInference)
        }

        switch semantic.formation {
        case .directExpression, .userCorrection:
            if isTemporaryScope(semantic, evidence: evidence) {
                return .internalOnly(reason: .temporaryScopeOnly)
            }
            return .remembered

        case .sourceLinked:
            // 单条日常流水（一笔饮料、一条未完成任务）不是个人记忆；明细由原模块提供。
            if semantic.evidenceForm == .independentEventSet,
               evidence.independentEventCount < 2,
               !semantic.applicability.windowRule.isBounded {
                return .internalOnly(reason: .routineFlowWithoutValue)
            }
            return .remembered

        case .behavioralInference:
            return assessInference(semantic: semantic, evidence: evidence)
        }
    }

    // MARK: 行为归纳：模板参数门禁（可测试配置）

    private static func assessInference(
        semantic: HoloKnowledgeSemantic,
        evidence: HoloKnowledgeEvidenceSnapshot
    ) -> HoloKnowledgeAdmissionVerdict {
        guard let rawTemplate = evidence.templateID,
              let templateID = HoloKnowledgeTemplateID(rawValue: rawTemplate) else {
            // 没有登记统计定义的指标仍能查询/关联事实，不能凭模型编一个数值规律上线。
            return .internalOnly(reason: .templateNotRegistered)
        }
        let template = HoloKnowledgeTemplateRegistry.parameters(for: templateID)
        if templateID == .boundedRecurrence {
            guard case .absolute(let from, let to) = semantic.applicability.windowRule,
                  let from, let to, from < to, to <= evidence.capturedAt,
                  from == evidence.observationWindowFrom, to == evidence.observationWindowTo,
                  Set(semantic.allowedUses).isSubset(of: [.sourceLinkForPreciseQuery]) else {
                return .reject(reason: .structureInvalid)
            }
        }
        guard template.allowedEvidenceForms.contains(semantic.evidenceForm) else {
            return .internalOnly(reason: .templateNotRegistered)
        }
        guard evidence.independentEventCount >= template.minIndependentEvents else {
            return .internalOnly(reason: .insufficientIndependentEvents)
        }
        guard let from = evidence.observationWindowFrom,
              let to = evidence.observationWindowTo,
              to.timeIntervalSince(from) >= TimeInterval(template.minSpanDays) * 86_400 else {
            return .internalOnly(reason: .insufficientSpan)
        }
        if template.minCoverage > 0 {
            guard let coverage = evidence.coveragePercent, coverage >= template.minCoverage else {
                return .internalOnly(reason: .insufficientCoverage)
            }
        }
        if template.requiresCounterexampleSearch {
            switch evidence.counterexampleSearch {
            case .notSearched:
                return .internalOnly(reason: .counterexampleSearchIncomplete)
            case .searchedFound:
                return .internalOnly(reason: .counterexampleFound)
            case .searchedNoneFound:
                break
            }
        }
        if template.holdoutPeriods > 0,
           (evidence.holdoutValidatedPeriods ?? 0) < template.holdoutPeriods {
            // 预先定义的比较与从大量候选中挑选的结果区别处理：检索命中再送一次模型不算独立验证。
            return .internalOnly(reason: .holdoutNotValidated)
        }
        // 跨度足够 ≠ 周期完整（09-R12）：28 天可能只有 3 个完整周；未提供完整周期数按不足处理。
        guard let completePeriods = evidence.completePeriods,
              completePeriods >= template.minCompletePeriods else {
            return .internalOnly(reason: .insufficientCompletePeriods)
        }
        return .worthConfirming
    }

    // MARK: 一次性范围（§6.1 门禁 6 的结构化表达）

    static func isTemporaryScope(
        _ semantic: HoloKnowledgeSemantic,
        evidence: HoloKnowledgeEvidenceSnapshot
    ) -> Bool {
        guard semantic.applicability.conditionText == nil else { return false }
        guard case .absolute(let from, let to) = semantic.applicability.windowRule else { return false }
        let anchor = evidence.capturedAt
        // 终点或起点落在捕获时刻附近（今晚/这次），且不是过去的重要经历。
        let reference = to ?? from
        guard let reference else { return false }
        let delta = reference.timeIntervalSince(anchor)
        if delta < -temporaryScopeToleranceSeconds { return false } // 过去事件：保留
        return delta <= temporaryScopeToleranceSeconds
    }
}
