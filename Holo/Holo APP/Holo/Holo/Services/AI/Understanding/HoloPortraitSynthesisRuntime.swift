//
//  HoloPortraitSynthesisRuntime.swift
//  Holo
//
//  Phase 2：全局画像与跨模块洞察运行时编排器。
//  职责：
//  1) 按智能节流（默认 72h 或检测到新跨模块异常且距上次 ≥20h）调用 HoloLifeFeatureDataSource
//     蒸馏七域特征包；
//  2) 通过 portrait_synthesis 通道调用云端 Flash 模型（单次全局推理，携带当前画像与已否决黑名单）；
//  3) 经 PortraitSafetyGate 过滤后写入本地 PortraitStore，并同步桥接至统一知识库（CloudKit 兼容）。
//

import Foundation

nonisolated protocol PortraitSynthesisClient: Sendable {
    func synthesize(payload: PortraitSynthesisRequestPayload) async throws -> PortraitDeltaEnvelope
}

struct RealPortraitSynthesisClient: PortraitSynthesisClient {
    func synthesize(payload: PortraitSynthesisRequestPayload) async throws -> PortraitDeltaEnvelope {
        guard let json = payload.encodeJSON() else {
            throw PortraitDeltaParseError.invalidJSON
        }
        let messages: [ChatMessageDTO] = [
            .user(json)
        ]
        let provider = await MainActor.run { HoloBackendAIProvider() }
        let raw = try await provider.chat(messages: messages, purpose: .portraitSynthesis)
        return try PortraitDeltaParser.parse(from: raw)
    }
}

nonisolated struct PortraitSynthesisRunResult: Equatable, Sendable {
    var ran: Bool
    var skipReason: String?
    var packetTokens: Int
    var applyReport: PortraitApplyReport?
    var promotedToMemoryCount: Int
    var errorMessage: String?
}

@MainActor
enum HoloPortraitSynthesisRuntime {

    private static var isRunning = false
    /// 常规周期：3 天一轮全局画像合成。
    static let normalInterval: TimeInterval = 72 * 3_600
    /// 检测到新跨模块异常时的最短重试间隔：20 小时。
    static let anomalyMinInterval: TimeInterval = 20 * 3_600

    static func storeDirectory() -> URL {
        UnderstandingShadowRunner.storageDirectory()
    }

    static func loadStore() -> PortraitStore {
        PortraitStore.load(directory: storeDirectory())
    }

    /// 用户一键确认某条推测画像（inferred → confirmed）。
    static func confirmEntry(key: String, now: Date = Date()) {
        let dir = storeDirectory()
        var store = PortraitStore.load(directory: dir)
        store.confirm(key: key, now: now)
        try? store.save(to: dir)
    }

    /// 用户一键否决某条画像或洞察（移出活跃态 + 写入黑名单永不复活）。
    static func rejectEntry(key: String, reason: String? = nil, now: Date = Date()) {
        let dir = storeDirectory()
        var store = PortraitStore.load(directory: dir)
        store.reject(key: key, reason: reason, now: now)
        try? store.save(to: dir)
    }

    /// 日常/按需运行一轮全局画像与跨模块洞察合成。
    static func runIfDue(
        force: Bool = false,
        now: Date = Date(),
        client: PortraitSynthesisClient = RealPortraitSynthesisClient()
    ) async -> PortraitSynthesisRunResult {
        guard !isRunning else {
            return PortraitSynthesisRunResult(
                ran: false, skipReason: "单飞保护：已有合成在途",
                packetTokens: 0, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
            )
        }
        guard HoloAIDataProcessingConsent.shared.isGranted else {
            return PortraitSynthesisRunResult(
                ran: false, skipReason: "未开启 AI 数据处理授权",
                packetTokens: 0, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
            )
        }
        guard force || HoloMemorySettings.shared.automaticMemoryEnabled else {
            return PortraitSynthesisRunResult(
                ran: false, skipReason: "自动形成记忆开关已关闭",
                packetTokens: 0, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
            )
        }

        isRunning = true
        defer { isRunning = false }

        guard let packet = await HoloLifeFeatureDataSource.buildPacket(now: now) else {
            return PortraitSynthesisRunResult(
                ran: false, skipReason: "特征包为空",
                packetTokens: 0, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
            )
        }

        let dir = storeDirectory()
        var store = PortraitStore.load(directory: dir)
        let anomalySig = packet.anomalies.map(\.code).sorted().joined(separator: ",")

        if !force, let last = store.lastSynthesizedAt {
            let elapsed = now.timeIntervalSince(last)
            let hasNewAnomaly = !anomalySig.isEmpty && anomalySig != store.lastAnomalySignature
            if elapsed < anomalyMinInterval {
                return PortraitSynthesisRunResult(
                    ran: false, skipReason: "20h 冷却期内",
                    packetTokens: packet.estimatedTokens, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
                )
            }
            if elapsed < normalInterval && !hasNewAnomaly {
                return PortraitSynthesisRunResult(
                    ran: false, skipReason: "72h 常规周期内且无新异常",
                    packetTokens: packet.estimatedTokens, applyReport: nil, promotedToMemoryCount: 0, errorMessage: nil
                )
            }
        }

        let payload = store.buildPromptPayload(packet: packet)
        do {
            let delta = try await client.synthesize(payload: payload)
            let report = store.apply(delta: delta, now: now)
            store.lastAnomalySignature = anomalySig
            try? store.save(to: dir)

            let promotedCount = await promoteToMemoryIfEnabled(
                upsertedKeys: report.upsertedKeys,
                store: store,
                now: now
            )

            NSLog("[HoloPortraitSynthesis] 完成: tokens=%d, 更新=%d, 退场=%d, 拦截=%d, 追问=%d, 入库=%d",
                  packet.estimatedTokens,
                  report.upsertedKeys.count,
                  report.retiredKeys.count,
                  report.rejectedByGate.count,
                  report.clarificationCount,
                  promotedCount)

            return PortraitSynthesisRunResult(
                ran: true,
                skipReason: nil,
                packetTokens: packet.estimatedTokens,
                applyReport: report,
                promotedToMemoryCount: promotedCount,
                errorMessage: nil
            )
        } catch {
            NSLog("[HoloPortraitSynthesis] 合成失败（不重试）: %@", String(describing: error))
            return PortraitSynthesisRunResult(
                ran: true,
                skipReason: nil,
                packetTokens: packet.estimatedTokens,
                applyReport: nil,
                promotedToMemoryCount: 0,
                errorMessage: String(describing: error)
            )
        }
    }

    // MARK: - 桥接统一知识库（复用 CloudKit 同步与墓碑防复活）

    private static func promoteToMemoryIfEnabled(
        upsertedKeys: [String],
        store: PortraitStore,
        now: Date
    ) async -> Int {
        guard UnderstandingPromotion.isEnabled, !upsertedKeys.isEmpty else { return 0 }
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return 0 }

        var byDomain: [HoloMemoryDomain: [HoloMemoryRecord]] = [:]
        for key in upsertedKeys {
            guard let entry = store.entries[key],
                  entry.confidence == .confirmed || entry.confidence == .inferred,
                  let record = makeMemoryRecord(from: entry, now: now),
                  let domain = record.primaryDomain else {
                continue
            }
            byDomain[domain, default: []].append(record)
        }

        var promoted = 0
        for (domain, batch) in byDomain {
            if let results = try? await repository.applyObservationBatch(
                batch,
                observationKey: "portrait-synthesis-\(Int(now.timeIntervalSince1970))-\(domain.rawValue)",
                domain: domain,
                extractorVersion: 2,
                promptVersion: 1,
                completedAt: now
            ) {
                promoted += results.filter { $0 == .inserted || $0 == .updated }.count
            }
        }
        return promoted
    }

    private static func makeMemoryRecord(from entry: PortraitEntry, now: Date) -> HoloMemoryRecord? {
        let primaryDomain = mapDomain(entry.sourceDomains.first)
        let anchorType: HoloMemoryAnchorType = {
            switch primaryDomain {
            case .finance: return .financeCategory
            case .health: return .healthMetric
            case .habit: return .habit
            case .task: return .task
            case .goal: return .goal
            case .conversation: return .conversation
            case .profile: return .profile
            case .thought: return .thoughtTopic
            }
        }()
        guard let anchor = try? HoloMemoryAnchorRef(
            type: anchorType,
            value: "portrait_\(entry.key)",
            displayLabel: entry.dimension.displayTitle
        ) else { return nil }

        let claimKind: HoloMemoryClaimKind = {
            switch entry.dimension {
            case .identity: return .observedFact
            case .longTermPattern: return .recurringPattern
            case .preference: return .explicitPreference
            case .recentState: return .phaseShift
            case .crossDomainInsight: return .association
            }
        }()

        let persistence: HoloMemoryPersistenceClass = {
            switch entry.dimension {
            case .identity, .preference: return .durable
            case .longTermPattern: return .phase
            case .recentState, .crossDomainInsight: return .currentState
            }
        }()

        let evidenceRef = HoloMemoryEvidenceRef(
            id: "portrait-\(entry.key)",
            kind: entry.confidence == .confirmed ? .explicitUserStatement : .entityRef,
            sourceDomain: primaryDomain,
            lineageKey: "portrait:\(entry.key)",
            sourceID: "portrait:\(entry.key)",
            revisionDigest: "\(Int(entry.updatedAt.timeIntervalSince1970))",
            observedAt: entry.updatedAt,
            validFrom: nil,
            validTo: nil,
            aggregateDefinition: nil,
            sampleCount: nil,
            summary: entry.evidenceSummary
        )

        let payload = HoloPersonalContextPayloadV1(
            contextID: "portrait-\(entry.key)",
            statement: entry.statement,
            relationText: entry.dimension.rawValue,
            epistemicStatus: entry.confidence == .confirmed ? .declared : .inferred,
            applicability: HoloContextApplicabilityV1(),
            temporal: HoloContextTemporalV1(
                kind: entry.dimension == .crossDomainInsight ? .conditional : .ongoing,
                originalExpression: entry.statement,
                precision: .day,
                validFrom: entry.updatedAt,
                validTo: nil,
                recurrence: nil,
                triggerText: nil
            ),
            basis: [
                HoloContextBasisRef(
                    sourceID: "portrait:\(entry.key)",
                    evidenceID: entry.key,
                    quote: String(entry.evidenceSummary.prefix(50)),
                    quoteUTF16Location: nil,
                    quoteUTF16Length: nil,
                    eventID: nil,
                    stance: .support,
                    sourceRevision: "\(Int(entry.updatedAt.timeIntervalSince1970))"
                )
            ],
            linkedContextIDs: [],
            openQuestions: [],
            admission: HoloContextAdmissionV1(
                level: .unreviewed,
                policyVersion: 2,
                decidedAt: now
            )
        )

        guard let id = try? HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: primaryDomain,
            sourceDomains: [primaryDomain],
            claimKind: claimKind,
            anchors: [anchor]
        ) else { return nil }

        let aiSummary = entry.confidence == .inferred
            ? "[\(entry.dimension.displayTitle)·推测] \(entry.statement)（用途：\(entry.usageHint)）"
            : "[\(entry.dimension.displayTitle)·已确认] \(entry.statement)（用途：\(entry.usageHint)）"

        var record = HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: primaryDomain,
            sourceDomains: [primaryDomain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: persistence,
            displaySummary: String(entry.statement.prefix(500)),
            aiUseSummary: String(aiSummary.prefix(500)),
            prohibitedInferences: [],
            evidenceRefs: [evidenceRef],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: entry.updatedAt,
            validTo: nil,
            lastSupportedAt: entry.updatedAt,
            expiresAt: nil,
            confidenceScore: entry.confidence == .confirmed ? 0.92 : 0.72,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 2,
            promptVersion: 1,
            lastObservationKey: nil,
            state: .candidate,
            sensitivity: .normal,
            userDecision: entry.isUserConfirmed ? .confirmed : .none,
            createdAt: now,
            updatedAt: now
        )
        record.personalContext = HoloPersonalContextPayloadEnvelope(v1: payload)
        guard (try? record.validate()) != nil,
              let adopted = HoloMemoryActivationPolicy.apply(to: record, now: now),
              (try? adopted.validate()) != nil else {
            return nil
        }
        return adopted
    }

    private static func mapDomain(_ raw: String?) -> HoloMemoryDomain {
        switch raw?.lowercased() {
        case "finance": return .finance
        case "health": return .health
        case "habit": return .habit
        case "task": return .task
        case "goal": return .goal
        case "chat", "conversation": return .conversation
        case "profile": return .profile
        default: return .thought
        }
    }
}
