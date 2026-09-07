//
//  HoloContextReconciler.swift
//  Holo
//
//  通用个人情境的稳定身份、归并与准入决策（实施方案 §4.4/§6 步骤 7）。
//
//  - 模型只给 candidateRef / mergeInto；程序映射到真实 ID 与 contextID。
//  - 合并要求结构签名一致（主体/对象/范围/命题），只有主题相同不得合并。
//  - 验证 verdict 驱动 admission：unsupported+inferred 丢弃、unsupported+声明类
//    转待确认、qualified 附限定词。模型自报 declared 不是免审通行证。
//  - claimKind 由程序按时间/知识状态/视角映射，不因过采用门槛改写。
//  - 纯逻辑，可 standalone 编译。
//

import Foundation

nonisolated enum HoloContextReconcileAction: Equatable, Sendable {
    /// 新建候选记录。
    case create
    /// 并入既有记录（结构签名一致，复用 contextID 与稳定 ID）。
    case mergeIntoExisting(recordID: String)
    /// 丢弃（验证不支持且属推断）。
    case discard(reason: String)
}

nonisolated struct HoloContextReconcileDecision: Sendable {
    var action: HoloContextReconcileAction
    /// create 时为新分配的载荷。
    var payload: HoloPersonalContextPayloadV1?
    /// create 时对应的 claimKind。
    var claimKind: HoloMemoryClaimKind?
    /// 记录敏感性：继承底层证据最高级别。
    var sensitivity: HoloMemorySensitivity
}

nonisolated enum HoloContextReconciler {
    /// admission policy 版本（verdict→准入映射的规则版本）。
    static let admissionPolicyVersion = 1

    /// 把（净化后的）候选 + 核验 verdict 归并为落库决策。
    /// - Parameters:
    ///   - candidates: 结构校验通过的候选。
    ///   - verdicts: 语义核验结果（缺项按未审核处理，不默认通过）。
    ///   - existingRecords: 同来源域既有情境记录（供 mergeInto 匹配验证）。
    ///   - packageSources: 输入包来源（敏感性继承）。
    ///   - now: 时间。
    static func reconcile(
        candidates: [HoloContextExtractionCandidateDTO],
        verdicts: [HoloContextVerificationVerdict],
        existingRecords: [HoloMemoryRecord],
        packageSources: [HoloContextSourceSnapshot],
        now: Date
    ) -> [HoloContextReconcileDecision] {
        let verdictByRef = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.candidateRef, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: packageSources.map { ($0.sourceID, $0) })

        return candidates.map { candidate in
            let ref = candidate.candidateRef
            let verdict = verdictByRef[ref]
            let epistemic = parseEpistemic(candidate.epistemicStatus)

            // 无 verdict = 未审核：一律 confirmationOnly，不得默认通过。
            guard let verdict else {
                return decision(
                    for: candidate,
                    epistemic: epistemic,
                    admission: .init(level: .confirmationOnly, policyVersion: admissionPolicyVersion, decidedAt: now, reason: "未核验"),
                    verdictQualifiers: [],
                    existingRecords: existingRecords,
                    sourcesByID: sourcesByID,
                    now: now
                )
            }

            switch verdict.verdict {
            case .unsupported:
                // 推断不支持 → 丢弃；声明/观察类不支持 → 交用户裁决。
                if epistemic == .inferred {
                    return HoloContextReconcileDecision(
                        action: .discard(reason: verdict.reason ?? "核验不支持"),
                        payload: nil,
                        claimKind: nil,
                        sensitivity: .normal
                    )
                }
                return decision(
                    for: candidate,
                    epistemic: epistemic,
                    admission: .init(level: .confirmationOnly, policyVersion: admissionPolicyVersion, decidedAt: now, reason: "核验不支持，待用户裁决"),
                    verdictQualifiers: [],
                    existingRecords: existingRecords,
                    sourcesByID: sourcesByID,
                    now: now
                )
            case .supported, .qualified:
                let qualifiers = verdict.requiredQualifiers ?? []
                let level: HoloContextAdmissionLevel = .adviceEligible
                return decision(
                    for: candidate,
                    epistemic: epistemic,
                    admission: .init(
                        level: level,
                        policyVersion: admissionPolicyVersion,
                        decidedAt: now,
                        reason: verdict.verdict == .qualified ? "qualified：\(qualifiers.joined(separator: "；"))" : (verdict.reason ?? "supported")
                    ),
                    verdictQualifiers: qualifiers,
                    existingRecords: existingRecords,
                    sourcesByID: sourcesByID,
                    now: now
                )
            }
        }
    }

    // MARK: - 私有

    private static func decision(
        for candidate: HoloContextExtractionCandidateDTO,
        epistemic: HoloContextEpistemicStatus,
        admission: HoloContextAdmissionV1,
        verdictQualifiers: [String],
        existingRecords: [HoloMemoryRecord],
        sourcesByID: [String: HoloContextSourceSnapshot],
        now: Date
    ) -> HoloContextReconcileDecision {
        // 敏感性继承：底层证据最高级别（normal < highImpact < sensitive）。
        let order: [HoloMemorySensitivity] = [.normal, .highImpact, .sensitive]
        let sensitivity = candidate.basis.reduce(HoloMemorySensitivity.normal) { current, basis in
            let source = sourcesByID[basis.sourceID]?.sensitivity ?? .normal
            return max(order.firstIndex(of: current) ?? 0, order.firstIndex(of: source) ?? 0) == (order.firstIndex(of: source) ?? 0)
                ? source
                : current
        }
        // 敏感来源的候选保持待确认（§5）。
        var admission = admission
        if sensitivity != .normal {
            admission = HoloContextAdmissionV1(
                level: .confirmationOnly,
                policyVersion: admission.policyVersion,
                decidedAt: now,
                reason: "敏感来源待确认"
            )
        }

        // 命题：qualified 附必要限定（推断类保留「从记录看/可能」等限定）。
        var statement = candidate.statement
        if !verdictQualifiers.isEmpty {
            statement = "\(statement)（\(verdictQualifiers.joined(separator: "；"))）"
        }
        if epistemic == .inferred && !statement.contains("可能") && !statement.contains("从记录看") && !statement.contains("目前") {
            statement = "从记录看，\(statement)"
        }

        let payload = HoloPersonalContextPayloadV1(
            contextID: UUID().uuidString,
            statement: statement,
            subjects: candidate.subjects ?? [],
            objects: candidate.objects ?? [],
            relationText: candidate.relationText ?? statement,
            facets: candidate.facets ?? [HoloContextFacet(kind: .other)],
            epistemicStatus: epistemic,
            applicability: candidate.applicability ?? HoloContextApplicabilityV1(),
            temporal: candidate.temporal,
            basis: candidate.basis.map { basis in
                HoloContextBasisRef(
                    sourceID: basis.sourceID,
                    quote: basis.quote,
                    stance: basis.stance == "contradiction" ? .contradiction : .support,
                    sourceRevision: basis.revision
                        ?? sourcesByID[basis.sourceID]?.revisionDigest
                        ?? "unknown"
                )
            },
            linkedContextIDs: [],
            openQuestions: candidate.openQuestions ?? [],
            admission: admission
        )

        // 合并判定：签名一致的既有记录一律合并（程序侧去重，防同命题重复创建）；
        // 模型的 mergeInto 只是加速路径——指向已落库 contextID 时直接命中。
        // 只有主题相同不得合并（§4.4）。
        if let target = existingRecords.first(where: { record in
            guard let existing = record.personalContext?.v1 else { return false }
            if let mergeRef = candidate.mergeInto, existing.contextID == mergeRef {
                return true
            }
            return existing.signatureComponentsEqual(payload)
        }) {
            return HoloContextReconcileDecision(
                action: .mergeIntoExisting(recordID: target.id),
                payload: payload,
                claimKind: nil,
                sensitivity: sensitivity
            )
        }

        return HoloContextReconcileDecision(
            action: .create,
            payload: payload,
            claimKind: claimKind(for: candidate, epistemic: epistemic),
            sensitivity: sensitivity
        )
    }

    /// claimKind 映射（§4.2）：不为了过采用门槛改写。
    static func claimKind(
        for candidate: HoloContextExtractionCandidateDTO,
        epistemic: HoloContextEpistemicStatus
    ) -> HoloMemoryClaimKind {
        if epistemic == .inferred { return .hypothesis }
        if candidate.temporal?.kind == .recurring { return .recurringPattern }
        if epistemic == .declared,
           candidate.facets?.contains(where: { $0.kind == .preference }) == true {
            return .explicitPreference
        }
        return .observedFact
    }

    private static func parseEpistemic(_ raw: String?) -> HoloContextEpistemicStatus {
        switch raw {
        case "declared": return .declared
        case "observed": return .observed
        case "inferred": return .inferred
        default: return .observed
        }
    }
}
