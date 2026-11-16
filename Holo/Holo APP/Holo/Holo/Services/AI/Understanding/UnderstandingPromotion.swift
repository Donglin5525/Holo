//
//  UnderstandingPromotion.swift
//  Holo
//
//  M3.1 上岗写入器（2026-11-15 设计定稿=10-M3上岗通道.md）：影子台账
//  adoptable 且 usage=explicitBackground 的候选 → 翻译 HoloMemoryRecord →
//  既有 applyObservationBatch 正门（record 入库 + HoloKnowledgeIngestion.ingest
//  同事务：准入二次审/幂等/墓碑防复活/CloudKit 归并四防线全复用）。
//
//  灰度 v1：DEBUG 恒开、Release 恒关——东林日用机=开发构建先享。
//  三标记映射（水位体系 → 知识契约）：
//    provenance: stated→payload.epistemicStatus=.declared（basis 挂想法原话域
//                → formation=directExpression）；recorded→.inferred（behavioralInference）
//    validity:   phase/enduring→temporal.kind=.ongoing；conditional→.conditional
//    usage:      explicitBackground→allowedUses 默认集（background+sourceLink，不塞 useLevel）
//

import Foundation

nonisolated struct PromotionError: LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor
enum UnderstandingPromotion {

    /// 灰度闸 v1（M3.3 换远配）。
    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - 映射表（纯函数）

    static func claimKind(_ kind: ProposalCandidate.ClaimKind) -> HoloMemoryClaimKind {
        switch kind {
        case .role: return .observedFact
        case .preference: return .explicitPreference
        case .recurringBehavior: return .recurringPattern
        case .phaseState: return .phaseShift
        case .conditionalAssociation: return .association
        }
    }

    static func epistemicStatus(_ provenance: EpistemicProvenance) -> HoloContextEpistemicStatus {
        switch provenance {
        case .stated: return .declared
        case .recorded, .inferred: return .inferred
        }
    }

    static func temporalKind(_ validity: EpistemicValidity) -> HoloContextTemporalKind {
        switch validity {
        case .phase, .enduring: return .ongoing
        case .conditional: return .conditional
        case .moment: return .event
        }
    }

    /// 持久档映射（HoloMemoryPersistenceClass）：阶段→phase、持续→durable、
    /// 条件关联/单次→currentState。
    static func persistenceClass(_ validity: EpistemicValidity) -> HoloMemoryPersistenceClass {
        switch validity {
        case .phase: return .phase
        case .enduring: return .durable
        case .conditional, .moment: return .currentState
        }
    }

    static func anchorType(primaryDomain: ObservationDomain) -> HoloMemoryAnchorType {
        switch primaryDomain {
        case .finance: return .financeCategory
        case .thought: return .thoughtTopic
        case .habit: return .habit
        case .health: return .healthMetric
        case .task: return .task
        case .goal: return .goal
        case .chat: return .conversation
        }
    }

    static func memoryDomain(_ domain: ObservationDomain) -> HoloMemoryDomain {
        switch domain {
        case .finance: return .finance
        case .thought: return .thought
        case .health: return .health
        case .habit: return .habit
        case .task: return .task
        case .goal: return .goal
        case .chat: return .conversation
        }
    }

    // MARK: - 翻译（影子候选材料 → HoloMemoryRecord）

    /// 纯函数（standalone 无关，App 构建即验证）：null 返回=不可翻译（无证据）。
    static func makeRecord(statement: String,
                           kind: ProposalCandidate.ClaimKind,
                           provenance: EpistemicProvenance,
                           validity: EpistemicValidity,
                           themeKey: String,
                           evidence: [LifeObservation],
                           now: Date) throws -> HoloMemoryRecord {
        guard !evidence.isEmpty else { throw PromotionError("证据空(0条)") }
        let domains = Set(evidence.map(\.domain))
        // 主域=证据里占比最大（平票按 rawValue 稳定序）；id/锚/入库域都用它。
        var counts: [ObservationDomain: Int] = [:]
        for obs in evidence { counts[obs.domain, default: 0] += 1 }
        let primary: ObservationDomain
        if let best = counts.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        })?.key {
            primary = best
        } else {
            primary = .thought
        }
        let primaryMemoryDomain = memoryDomain(primary)
        // 知识身份的 domain scope 约束：sourceDomains 必须恰好=[primaryDomain]
        //（invalidDomainScope 实锤：戒烟主题含打卡+想法跨域成员，多域被拒）。
        // 跨域溯源不丢——每条 evidenceRefs 自带 sourceDomain。
        let sourceMemoryDomains = [primaryMemoryDomain]

        // 主题锚：themeKey 空值抛错 → 整条不可翻译。
        guard let anchor = try? HoloMemoryAnchorRef(
            type: anchorType(primaryDomain: primary),
            value: themeKey,
            displayLabel: themeKey) else { throw PromotionError("锚构造拒(themeKey=\(themeKey))") }

        // 证据引用：用户原话观察（quote）→ explicitUserStatement（isUserWordsDomain
        // 判定依据 lineageKey 的域前缀）；行为观察 → entityRef。
        let evidenceRefs: [HoloMemoryEvidenceRef] = evidence.map { obs in
            let sourceKey = "\(obs.domain.rawValue):\(obs.sourceRef)"
            return HoloMemoryEvidenceRef(
                id: "und-\(obs.sourceRef.prefix(36))",
                kind: obs.businessState == .quote ? .explicitUserStatement : .entityRef,
                sourceDomain: memoryDomain(obs.domain),
                lineageKey: sourceKey,
                sourceID: sourceKey,
                revisionDigest: obs.sourceRevision,
                observedAt: obs.occurredAt ?? obs.recordedAt,
                validFrom: nil, validTo: nil,
                aggregateDefinition: nil, sampleCount: nil, summary: nil)
        }

        // 观察窗起点=证据真实覆盖（G2-A03 同款：不用调度窗替代）。
        let observedDates = evidence.compactMap(\.occurredAt)
        let validFrom = observedDates.min()

        // payload：epistemicStatus 驱动 formation，temporal 驱动 applicability。
        let basis: [HoloContextBasisRef] = evidence.map { obs in
            HoloContextBasisRef(
                sourceID: "\(obs.domain.rawValue):\(obs.sourceRef)",
                evidenceID: obs.sourceRef,
                quote: obs.quote.map { String($0.prefix(50)) },
                quoteUTF16Location: nil,
                quoteUTF16Length: nil,
                eventID: nil,
                stance: .support,
                sourceRevision: obs.sourceRevision)
        }
        let payload = HoloPersonalContextPayloadV1(
            contextID: "understanding-\(themeKey)-\(Int(now.timeIntervalSince1970))",
            statement: statement,
            relationText: kind.rawValue,
            epistemicStatus: epistemicStatus(provenance),
            applicability: HoloContextApplicabilityV1(),
            temporal: HoloContextTemporalV1(
                kind: temporalKind(validity),
                originalExpression: statement,
                precision: .day,
                // 进行中认识的适用期没有终点：validTo 语义=「适用到何时」而非
                // 「证据观察到何时」——填最后证据时刻会把进行中阶段判过期
                //（isExpired 首条 validTo<now 即弃；真数据实锤：断卡几日的戒烟
                // 被 discard、当天打过卡的维生素侥幸通过）。起点保留=阶段开始。
                validFrom: validFrom,
                validTo: nil,
                recurrence: nil,
                triggerText: nil),
            basis: basis,
            linkedContextIDs: [],
            openQuestions: [],
            admission: HoloContextAdmissionV1(
                level: .unreviewed,
                policyVersion: 1,
                decidedAt: now))

        do {
            let id = try HoloMemoryIdentity.makeStableID(
                scope: .domain,
                primaryDomain: primaryMemoryDomain,
                sourceDomains: sourceMemoryDomains,
                claimKind: claimKind(kind),
                anchors: [anchor])
            var record = HoloMemoryRecord(
                id: id,
                scope: .domain,
                primaryDomain: primaryMemoryDomain,
                sourceDomains: sourceMemoryDomains,
                subjectKey: anchor.stableKey,
                anchorRefs: [anchor],
                claimKind: claimKind(kind),
                persistenceClass: persistenceClass(validity),
                displaySummary: String(statement.prefix(500)),
                aiUseSummary: String(statement.prefix(500)),
                prohibitedInferences: [],
                evidenceRefs: evidenceRefs,
                upstreamMemoryIDs: [],
                counterEvidenceRefs: [],
                validFrom: validFrom,
                // 观察窗终点同款不填（isCurrentStateClaim 分支拿 record.validTo<now
                // 判过期——每天打卡的习惯永远处在「最后一次在昨天」，填终点=必过期）。
                validTo: nil,
                lastSupportedAt: observedDates.max() ?? now,
                expiresAt: nil,
                confidenceScore: min(0.9, 0.55 + Double(evidenceRefs.count) * 0.1),
                freshnessScore: 1,
                scoringVersion: HoloMemoryScorer.currentVersion,
                scoreComputedAt: now,
                extractorVersion: 1,
                promptVersion: 1,
                lastObservationKey: nil,
                state: .candidate,
                sensitivity: .normal,
                userDecision: .none,
                createdAt: now,
                updatedAt: now)
            record.personalContext = HoloPersonalContextPayloadEnvelope(v1: payload)
            try record.validate()
            guard let adopted = HoloMemoryActivationPolicy.apply(to: record, now: now) else {
                throw PromotionError("激活策略拒(决策路由discard)")
            }
            try adopted.validate()
            return adopted
        }
    }

    // MARK: - 晋升执行（影子轮终态后调用）

    /// 读台账 adoptable 条目 → 翻译 → applyObservationBatch 正门入库
    ///（幂等：observationKey 按轮次时间戳，同轮重放被 duplicateObservation 挡）。
    /// 返回（晋升数, 跳过数, 失败原因列表）——影子报告可追溯。
    static func promoteEligible(ledger: ShadowLedger,
                                resolveEvidence: (ShadowCandidate) -> [LifeObservation],
                                now: Date) async -> (promoted: Int, skipped: Int, failures: [String]) {
        guard isEnabled else { return (0, 0, []) }
        let eligible = ledger.snapshot(stage: .adoptable).filter { $0.usage == .explicitBackground }
        guard !eligible.isEmpty else { return (0, 0, []) }

        var records: [HoloMemoryRecord] = []
        var skipped = 0
        var failures: [String] = []
        for candidate in eligible {
            guard let statement = candidate.statement, !statement.isEmpty,
                  let kind = ProposalCandidate.ClaimKind(rawValue: candidate.claimType ?? ""),
                  let provenance = candidate.provenance,
                  let validity = candidate.validity else {
                NSLog("[UnderstandingPromotion] 字段缺失跳过 stmt=%@ claim=%@ prov=%@ val=%@",
                      candidate.statement ?? "nil", candidate.claimType ?? "nil",
                      String(describing: candidate.provenance), String(describing: candidate.validity))
                skipped += 1
                continue
            }
            let evidence = resolveEvidence(candidate)
            do {
                let record = try makeRecord(
                    statement: statement, kind: kind, provenance: provenance, validity: validity,
                    themeKey: candidate.themeKey, evidence: evidence, now: now)
                records.append(record)
            } catch {
                skipped += 1
                failures.append("[\(candidate.themeKey)] 翻译失败:\(error.localizedDescription)")
                continue
            }
        }
        guard !records.isEmpty else { return (0, skipped, failures) }

        // 主域一致才可同批（applyObservationBatch 约束 primaryDomain == domain）；
        // 混域主题的 primary 已定，逐域分批入。仓储走统一运行时（含模拟器验证环境分流）。
        var byDomain: [HoloMemoryDomain: [HoloMemoryRecord]] = [:]
        for record in records {
            guard let domain = record.primaryDomain else { continue }
            byDomain[domain, default: []].append(record)
        }
        var promoted = 0
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            for (domain, batch) in byDomain {
                do {
                    let results = try await repository.applyObservationBatch(
                        batch,
                        observationKey: "understanding-promotion-\(Int(now.timeIntervalSince1970))-\(domain.rawValue)",
                        domain: domain,
                        extractorVersion: 1,
                        promptVersion: 1,
                        completedAt: now)
                    promoted += results.filter { $0 == .inserted || $0 == .updated }.count
                } catch {
                    failures.append("[\(domain.rawValue)] 入库失败: \(String(describing: error).prefix(80))")
                }
            }
        } catch {
            failures.append("仓储不可得: \(String(describing: error).prefix(80))")
        }
        return (promoted, skipped, failures)
    }
}
