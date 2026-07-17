#if DEBUG
//
//  HoloMemorySimulatorValidationScenario.swift
//  Holo
//
//  iOS Simulator 隔离记忆全链路验收：无页面、无外部 AI、无 iCloud。
//

import Foundation
import OSLog

nonisolated enum HoloMemorySimulatorValidationFixtureRole: String, Codable, CaseIterable, Sendable {
    case financeActive
    case healthCandidate
    case habitActive
    case correctionActive
    case rejectionActive
    case deletionActive
}

nonisolated struct HoloMemorySimulatorValidationDomainFixture: Sendable {
    var role: HoloMemorySimulatorValidationFixtureRole
    var package: HoloDomainObservationPackage
    var modelOutput: Data
    var observationKey: String
}

nonisolated struct HoloMemorySimulatorValidationAssertion: Codable, Equatable, Sendable {
    var name: String
    var passed: Bool
    var expected: String
    var actual: String
}

nonisolated struct HoloMemorySimulatorValidationQueryResult: Codable, Equatable, Sendable {
    var question: String
    var route: String
    var authority: String
    var requiresDetailData: Bool
    var selectedMemoryIDs: [String]
    var renderedContext: String
}

nonisolated struct HoloMemorySimulatorValidationReport: Codable, Equatable, Sendable {
    var scenario: String
    var startedAt: Date
    var completedAt: Date
    var status: String
    var assertions: [HoloMemorySimulatorValidationAssertion]
    var recordStates: [String: String]
    var queryResults: [HoloMemorySimulatorValidationQueryResult]

    var failedAssertionCount: Int { assertions.filter { !$0.passed }.count }
}

nonisolated enum HoloMemorySimulatorValidationFixtures {
    static let namespace = "sim-validation-v2"

    static func make(now: Date) throws -> [HoloMemorySimulatorValidationDomainFixture] {
        let window = HoloMemoryObservationWindow(
            start: now.addingTimeInterval(-14 * 86_400),
            end: now.addingTimeInterval(86_400)
        )
        let sharedGoal = try HoloMemoryAnchorRef(
            type: .goal,
            value: "\(namespace)-reduce-weight",
            displayLabel: "[模拟] 减脂"
        )
        let definitions: [FixtureDefinition] = [
            .init(
                role: .financeActive,
                domain: .finance,
                signalKind: .aggregate,
                evidenceKind: .aggregateSnapshot,
                sampleCount: 4,
                anchors: [
                    sharedGoal,
                    try HoloMemoryAnchorRef(
                        type: .merchant,
                        value: "麦当劳",
                        displayLabel: "麦当劳"
                    )
                ],
                claimKind: .recurringPattern,
                persistenceClass: .phase,
                displaySummary: "[模拟] 近14天有4次麦当劳消费记录",
                aiUseSummary: "[模拟] 近期存在重复麦当劳消费模式"
            ),
            .init(
                role: .healthCandidate,
                domain: .health,
                signalKind: .aggregate,
                evidenceKind: .aggregateSnapshot,
                sampleCount: 5,
                anchors: [
                    sharedGoal,
                    try HoloMemoryAnchorRef(
                        type: .healthMetric,
                        value: "sleep-onset",
                        displayLabel: "入睡时间"
                    )
                ],
                claimKind: .lifeEvent,
                persistenceClass: .phase,
                displaySummary: "[模拟] 近两周开始调整作息，入睡时间仍不稳定",
                aiUseSummary: "[模拟] 用户处于作息调整期，入睡时间波动较大"
            ),
            .init(
                role: .habitActive,
                domain: .habit,
                signalKind: .entity,
                evidenceKind: .entityRef,
                sampleCount: nil,
                anchors: [
                    sharedGoal,
                    try HoloMemoryAnchorRef(
                        type: .habit,
                        value: "\(namespace)-reduce-weight",
                        displayLabel: "[模拟] 减脂打卡"
                    )
                ],
                claimKind: .phaseShift,
                persistenceClass: .phase,
                displaySummary: "[模拟] 减脂习惯仍在尝试期",
                aiUseSummary: "[模拟] 减脂习惯尚未形成稳定节律"
            ),
            .init(
                role: .correctionActive,
                domain: .thought,
                signalKind: .entity,
                evidenceKind: .entityRef,
                sampleCount: nil,
                anchors: [
                    try HoloMemoryAnchorRef(
                        type: .thoughtTopic,
                        value: "\(namespace)-correction",
                        displayLabel: "[模拟] 纠正样本"
                    )
                ],
                claimKind: .observedFact,
                persistenceClass: .currentState,
                displaySummary: "[模拟] 这是纠正前的记忆",
                aiUseSummary: "[模拟] 纠正前样本"
            ),
            .init(
                role: .rejectionActive,
                domain: .task,
                signalKind: .entity,
                evidenceKind: .entityRef,
                sampleCount: nil,
                anchors: [
                    try HoloMemoryAnchorRef(
                        type: .task,
                        value: "\(namespace)-rejection",
                        displayLabel: "[模拟] 拒绝样本"
                    )
                ],
                claimKind: .observedFact,
                persistenceClass: .currentState,
                displaySummary: "[模拟] 这条记忆将被标记为不准确",
                aiUseSummary: "[模拟] 拒绝样本"
            ),
            .init(
                role: .deletionActive,
                domain: .goal,
                signalKind: .entity,
                evidenceKind: .entityRef,
                sampleCount: nil,
                anchors: [
                    try HoloMemoryAnchorRef(
                        type: .goal,
                        value: "\(namespace)-forgetting",
                        displayLabel: "[模拟] 忘记样本"
                    )
                ],
                claimKind: .observedFact,
                persistenceClass: .currentState,
                displaySummary: "[模拟] 这条记忆将被忘记",
                aiUseSummary: "[模拟] 忘记样本"
            )
        ]
        return try definitions.map { try makeFixture($0, window: window, now: now) }
    }

    private static func makeFixture(
        _ definition: FixtureDefinition,
        window: HoloMemoryObservationWindow,
        now: Date
    ) throws -> HoloMemorySimulatorValidationDomainFixture {
        let role = definition.role.rawValue
        let evidence = HoloMemoryEvidenceRef(
            id: "\(namespace)-evidence-\(role)",
            kind: definition.evidenceKind,
            sourceDomain: definition.domain,
            lineageKey: "\(namespace)-lineage-\(role)",
            sourceID: "\(namespace)-source-\(role)",
            revisionDigest: "\(namespace)-revision-1",
            observedAt: now.addingTimeInterval(-86_400),
            validFrom: window.start,
            validTo: window.end,
            aggregateDefinition: definition.sampleCount == nil ? nil : "\(namespace)-aggregate",
            sampleCount: definition.sampleCount,
            summary: "[模拟证据] \(role)"
        )
        let signal = try HoloDomainSignalBuilder.make(
            id: "\(namespace)-signal-\(role)",
            domain: definition.domain,
            kind: definition.signalKind,
            evidence: evidence,
            anchors: definition.anchors,
            numericFacts: definition.sampleCount.map { ["sampleCount": Double($0)] } ?? [:],
            prohibitedInferences: ["不推断因果或人格"]
        )
        let package = HoloDomainObservationPackageBuilder.build(
            domain: definition.domain,
            window: window,
            signals: [signal]
        )
        let candidate = HoloDomainMemoryCandidateOutput(
            domain: definition.domain,
            claimKind: definition.claimKind,
            persistenceClass: definition.persistenceClass,
            displaySummary: definition.displaySummary,
            aiUseSummary: definition.aiUseSummary,
            anchors: definition.anchors,
            evidenceIDs: [evidence.id],
            prohibitedInferences: ["不推断因果或人格"]
        )
        return HoloMemorySimulatorValidationDomainFixture(
            role: definition.role,
            package: package,
            modelOutput: try encodeModelOutputWithNullRequestedActions(candidate),
            observationKey: "\(namespace)-observation-\(role)"
        )
    }

    private static func encodeModelOutputWithNullRequestedActions(
        _ candidate: HoloDomainMemoryCandidateOutput
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(
            HoloDomainMemoryOutputEnvelope(candidates: [candidate])
        )
        guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var candidates = root["candidates"] as? [[String: Any]],
              !candidates.isEmpty else {
            throw HoloMemorySimulatorValidationFixtureError.invalidModelFixture
        }
        candidates[0]["requestedActions"] = NSNull()
        root["candidates"] = candidates
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private struct FixtureDefinition {
        var role: HoloMemorySimulatorValidationFixtureRole
        var domain: HoloMemoryDomain
        var signalKind: HoloDomainSignalKind
        var evidenceKind: HoloMemoryEvidenceKind
        var sampleCount: Int?
        var anchors: [HoloMemoryAnchorRef]
        var claimKind: HoloMemoryClaimKind
        var persistenceClass: HoloMemoryPersistenceClass
        var displaySummary: String
        var aiUseSummary: String
    }
}

nonisolated enum HoloMemorySimulatorValidationFixtureError: Error, Equatable {
    case invalidModelFixture
    case missingGeneratedRecord(HoloMemorySimulatorValidationFixtureRole)
    case missingCrossDomainCandidate
    case crossDomainPersistenceRejected
}

#if !HOLO_MEMORY_STANDALONE
@MainActor
enum HoloMemorySimulatorValidationScenario {
    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "MemorySimulatorValidation"
    )

    @discardableResult
    static func runIfRequested(now: Date = Date()) async -> Bool {
        guard let environment = HoloMemorySimulatorValidationEnvironment.current else {
            return false
        }
        if !environment.shouldReset,
           FileManager.default.fileExists(atPath: environment.reportURL.path) {
            logger.info("模拟器记忆验收报告已存在，保留现有数据")
            return true
        }

        let startedAt = now
        var recorder = AssertionRecorder()
        var recordIDs: [HoloMemorySimulatorValidationFixtureRole: String] = [:]
        var queryResults: [HoloMemorySimulatorValidationQueryResult] = []

        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            try await repository.saveControlState(HoloMemoryControlState(
                automaticMemoryEnabled: true,
                memoryAssistedAnsweringEnabled: true,
                learningBaselineAt: nil,
                userDecisionVersion: 1,
                updatedAt: now
            ))
            let fixtures = try HoloMemorySimulatorValidationFixtures.make(now: now)

            for fixture in fixtures {
                let validation = HoloDomainMemoryOutputValidator.decodeAndValidate(
                    fixture.modelOutput,
                    against: fixture.package,
                    now: now,
                    extractorVersion: 1,
                    promptVersion: 1
                )
                recorder.check(
                    validation.rejections.isEmpty,
                    name: "validator.\(fixture.role.rawValue).acceptsNullRequestedActions",
                    expected: "no rejections",
                    actual: validation.rejections.map(\.rawValue).joined(separator: ",")
                )
                guard let generated = validation.validRecords.first else {
                    throw HoloMemorySimulatorValidationFixtureError.missingGeneratedRecord(fixture.role)
                }
                recordIDs[fixture.role] = generated.id
                let results = try await HoloDomainMemoryObservationApplier.apply(
                    validation,
                    to: repository,
                    observationKey: fixture.observationKey,
                    domain: fixture.package.domain,
                    extractorVersion: 1,
                    promptVersion: 1,
                    completedAt: now
                )
                recorder.check(
                    results == [.inserted],
                    name: "repository.\(fixture.role.rawValue).inserted",
                    expected: "inserted",
                    actual: String(describing: results)
                )
                recorder.check(
                    generated.state == expectedInitialState(for: fixture.role),
                    name: "state.\(fixture.role.rawValue).initial",
                    expected: expectedInitialState(for: fixture.role).rawValue,
                    actual: generated.state.rawValue
                )
                HoloMemoryReceiptStore.record(
                    kind: .write,
                    channel: .insight,
                    memoryIDs: [generated.id],
                    message: generated.state == .active
                        ? "Holo 新记住了 1 件事"
                        : "有 1 件事想和你确认",
                    adoptionKind: generated.state == .active
                        ? .automaticallyAdopted
                        : .needsConfirmation,
                    batchKey: "\(fixture.observationKey):\(generated.state.rawValue)",
                    now: now
                )
            }

            if let financeFixture = fixtures.first(where: { $0.role == .financeActive }) {
                let validation = HoloDomainMemoryOutputValidator.decodeAndValidate(
                    financeFixture.modelOutput,
                    against: financeFixture.package,
                    now: now,
                    extractorVersion: 1,
                    promptVersion: 1
                )
                let duplicate = try await HoloDomainMemoryObservationApplier.apply(
                    validation,
                    to: repository,
                    observationKey: financeFixture.observationKey,
                    domain: financeFixture.package.domain,
                    extractorVersion: 1,
                    promptVersion: 1,
                    completedAt: now
                )
                recorder.check(
                    duplicate == [.duplicateObservation],
                    name: "repository.observationKey.idempotent",
                    expected: "duplicateObservation",
                    actual: String(describing: duplicate)
                )
            }

            guard var historicalCandidate = try await repository.fetch(
                id: recordIDs[.deletionActive] ?? ""
            ) else {
                throw HoloMemorySimulatorValidationFixtureError.missingGeneratedRecord(.deletionActive)
            }
            let historicalCreatedAt = now.addingTimeInterval(-420 * 86_400)
            let historicalSupportedAt = now.addingTimeInterval(-400 * 86_400)
            let historicalAnchor = try HoloMemoryAnchorRef(
                type: .goal,
                value: "\(HoloMemorySimulatorValidationFixtures.namespace)-historical",
                displayLabel: "[模拟] 历史候选"
            )
            historicalCandidate.anchorRefs = [historicalAnchor]
            historicalCandidate.subjectKey = historicalAnchor.stableKey
            historicalCandidate.id = try HoloMemoryIdentity.makeStableID(for: historicalCandidate)
            historicalCandidate.displaySummary = "[模拟] 很久以前的阶段目标"
            historicalCandidate.aiUseSummary = "[模拟] 很久以前存在阶段目标"
            historicalCandidate.evidenceRefs = historicalCandidate.evidenceRefs.map { evidence in
                var updated = evidence
                updated.id = "\(HoloMemorySimulatorValidationFixtures.namespace)-historical-evidence"
                updated.lineageKey = "\(HoloMemorySimulatorValidationFixtures.namespace)-historical-lineage"
                updated.observedAt = historicalSupportedAt
                updated.validFrom = historicalCreatedAt
                updated.validTo = historicalSupportedAt
                return updated
            }
            historicalCandidate.validFrom = historicalCreatedAt
            historicalCandidate.validTo = historicalSupportedAt
            historicalCandidate.lastSupportedAt = historicalSupportedAt
            historicalCandidate.createdAt = historicalCreatedAt
            historicalCandidate.updatedAt = historicalSupportedAt
            historicalCandidate.scoreComputedAt = historicalSupportedAt
            historicalCandidate.state = .candidate
            historicalCandidate.userDecision = .none
            historicalCandidate.adoptionMetadata = nil
            _ = try await repository.upsert(historicalCandidate, observationKey: nil)

            let migrationState = SimulatorMigrationStateStore()
            let migration = HoloMemoryMigrationService(
                repository: repository,
                stateStore: migrationState,
                journalURL: environment.storeDirectoryURL
                    .appendingPathComponent("memory-v4-simulator-journal.json"),
                allowDestructiveRerun: true,
                now: { now }
            )
            let migrationPreview = try migration.dryRun(snapshot: HoloLegacyMemorySnapshot(
                longTermMemories: [],
                episodicMemories: [],
                suppressionRules: []
            ))
            let migrationResult = try await migration.commit(migrationPreview)
            let migratedHistorical = try await repository.fetch(id: historicalCandidate.id)
            let preservesCreatedAt = (migratedHistorical?.createdAt).map {
                abs($0.timeIntervalSince(historicalCreatedAt)) < 1
            } == true
            let preservesLastSupportedAt = (migratedHistorical?.lastSupportedAt).map {
                abs($0.timeIntervalSince(historicalSupportedAt)) < 1
            } == true
            recorder.check(
                migrationResult == .committed(recordCount: 2, tombstoneCount: 0) &&
                    migratedHistorical?.state == .active &&
                    preservesCreatedAt &&
                    preservesLastSupportedAt &&
                    migratedHistorical?.adoptionMetadata?.disposition == .historicalMigration,
                name: "migration.historicalCandidates.activateWithoutRefreshingTime",
                expected: "all historical candidates active/original dates/historical metadata",
                actual: "result=\(String(describing: migrationResult)),state=\(migratedHistorical?.state.rawValue ?? "nil"),created=\(String(describing: migratedHistorical?.createdAt)),supported=\(String(describing: migratedHistorical?.lastSupportedAt))"
            )
            recorder.check(
                migratedHistorical.map { !HoloMemoryRecallPolicy.isEligible($0, now: now) } == true,
                name: "migration.oldCandidate.exitsRecallImmediately",
                expected: "not recall eligible",
                actual: "freshness=\(migratedHistorical.map { HoloMemoryRecallPolicy.effectiveFreshness(for: $0, now: now) } ?? -1)"
            )
            if let healthID = recordIDs[.healthCandidate],
               var health = try await repository.fetch(id: healthID) {
                let predecessor = health.versionID
                health.state = .candidate
                health.userDecision = .none
                health.adoptionMetadata = HoloMemoryAdoptionMetadata(
                    policyVersion: HoloMemoryActivationPolicy.currentVersion,
                    disposition: .pendingConfirmation,
                    reason: .permanentFact,
                    evaluatedAt: now
                )
                health.recordVersion += 1
                health.predecessorVersionID = predecessor
                health.updatedAt = now
                try await repository.replaceRecordForUserControl(health)
            }
            let compaction = try await HoloMemoryCompactionService().compact(
                repository: repository,
                now: now
            )
            let archivedHistorical = try await repository.fetch(id: historicalCandidate.id)
            recorder.check(
                compaction.archiveRecordIDs.contains(historicalCandidate.id) &&
                    archivedHistorical?.state == .archived,
                name: "lifecycle.staleCandidate.movesToPastMemory",
                expected: "archived",
                actual: String(describing: archivedHistorical?.state)
            )
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: [historicalCandidate.id],
                message: "已按新的记忆方式整理原有内容",
                adoptionKind: .historicalMigration,
                batchKey: "\(HoloMemorySimulatorValidationFixtures.namespace)-migration",
                now: now
            )

            let initialRecords = try await repository.query(.all)
            let crossCandidates = HoloCrossDomainCandidateBuilder.build(from: initialRecords)
            recorder.check(
                !crossCandidates.isEmpty,
                name: "fusion.fourGates.candidateExists",
                expected: "at least 1",
                actual: "\(crossCandidates.count)"
            )
            guard let crossCandidate = crossCandidates.first(where: {
                Set($0.sourceDomains) == Set([.finance, .habit])
            }) ?? crossCandidates.first else {
                throw HoloMemorySimulatorValidationFixtureError.missingCrossDomainCandidate
            }
            let fusionOutput = HoloCrossDomainFusionOutput(
                claimKind: .association,
                displaySummary: "[模拟] 减脂打卡期间同时出现重复快餐消费",
                aiUseSummary: "[模拟] 减脂习惯与快餐消费记录在同一阶段出现",
                anchors: [crossCandidate.sharedAnchor],
                upstreamMemoryIDs: crossCandidate.sourceMemoryIDs,
                evidenceIDs: crossCandidate.evidenceRefs.map(\.id),
                prohibitedInferences: ["不推断因果或医学结论"],
                requestedStorageClass: .normal
            )
            let fusionDecision = HoloCrossDomainFusionService.evaluate(
                fusionOutput,
                for: crossCandidate,
                priorOccurrenceCount: 0,
                userConfirmed: false,
                now: now
            )
            guard case .persist(let crossRecord) = fusionDecision else {
                throw HoloMemorySimulatorValidationFixtureError.crossDomainPersistenceRejected
            }
            let crossUpsert = try await repository.upsert(
                crossRecord,
                observationKey: "\(HoloMemorySimulatorValidationFixtures.namespace)-cross-observation"
            )
            recorder.check(
                crossUpsert == .inserted && crossRecord.state == .candidate,
                name: "fusion.firstCrossDomain.waitsForConfirmation",
                expected: "inserted/candidate",
                actual: "\(String(describing: crossUpsert))/\(crossRecord.state.rawValue)"
            )
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: [crossRecord.id],
                message: "有 1 件事想和你确认",
                adoptionKind: .needsConfirmation,
                batchKey: "\(HoloMemorySimulatorValidationFixtures.namespace)-cross-pending",
                now: now
            )

            let feedback = HoloMemoryFeedbackService(store: repository)
            _ = try await feedback.apply(
                .accurate,
                to: crossRecord.id,
                now: now.addingTimeInterval(1)
            )
            let confirmedCross = try await repository.fetch(id: crossRecord.id)
            recorder.check(
                confirmedCross?.state == .active && confirmedCross?.userDecision == .confirmed,
                name: "feedback.accurate.activatesFirstCrossDomain",
                expected: "active/confirmed",
                actual: "\(confirmedCross?.state.rawValue ?? "nil")/\(confirmedCross?.userDecision.rawValue ?? "nil")"
            )
            if let habitID = recordIDs[.habitActive] {
                _ = try await feedback.apply(.accurate, to: habitID, now: now.addingTimeInterval(2))
                let record = try await repository.fetch(id: habitID)
                recorder.check(
                    record?.state == .active && record?.userDecision == .confirmed,
                    name: "feedback.accurate.confirmsAutomaticMemory",
                    expected: "active/confirmed",
                    actual: "\(record?.state.rawValue ?? "nil")/\(record?.userDecision.rawValue ?? "nil")"
                )
            }
            if let correctionID = recordIDs[.correctionActive] {
                let before = try await repository.fetch(id: correctionID)
                let corrected = try await feedback.correct(
                    id: correctionID,
                    summary: "[模拟] 这是用户纠正后的记忆",
                    now: now.addingTimeInterval(3)
                )
                recorder.check(
                    corrected.id == correctionID &&
                        corrected.recordVersion == (before?.recordVersion ?? 0) + 1 &&
                        corrected.userDecision == .corrected &&
                        corrected.state == .active,
                    name: "feedback.correction.preservesIdentityAndVersions",
                    expected: "same ID/version+1/active/corrected",
                    actual: "id=\(corrected.id),version=\(corrected.recordVersion),state=\(corrected.state.rawValue),decision=\(corrected.userDecision.rawValue)"
                )
            }
            if let rejectionID = recordIDs[.rejectionActive] {
                _ = try await feedback.apply(.inaccurate, to: rejectionID, now: now.addingTimeInterval(4))
                let record = try await repository.fetch(id: rejectionID)
                recorder.check(
                    record?.state == .suppressed && record?.userDecision == .rejected,
                    name: "feedback.inaccurate.suppressesRecord",
                    expected: "suppressed/rejected",
                    actual: "\(record?.state.rawValue ?? "nil")/\(record?.userDecision.rawValue ?? "nil")"
                )
                let activeWhileRejected = Set(try await repository.query(.active).map(\.id))
                recorder.check(
                    !activeWhileRejected.contains(rejectionID),
                    name: "feedback.inaccurate.exitsRecallImmediately",
                    expected: "absent from active query",
                    actual: activeWhileRejected.contains(rejectionID) ? "present" : "absent"
                )
                _ = try await feedback.apply(.accurate, to: rejectionID, now: now.addingTimeInterval(5))
                let restored = try await repository.fetch(id: rejectionID)
                recorder.check(
                    restored?.state == .active && restored?.userDecision == .confirmed,
                    name: "feedback.inaccurate.canBeChangedBackToAccurate",
                    expected: "active/confirmed",
                    actual: "\(restored?.state.rawValue ?? "nil")/\(restored?.userDecision.rawValue ?? "nil")"
                )
            }
            if let deletionID = recordIDs[.deletionActive] {
                let original = try await repository.fetch(id: deletionID)
                _ = try await feedback.apply(.noLongerUse, to: deletionID, now: now.addingTimeInterval(6))
                let deleted = try await repository.fetch(id: deletionID)
                recorder.check(
                    deleted == nil,
                    name: "feedback.delete.removesCurrentRecord",
                    expected: "record missing",
                    actual: deleted == nil ? "missing" : "present"
                )
                let tombstone = try await repository.fetchTombstone(identityKey: deletionID)
                recorder.check(
                    tombstone == nil,
                    name: "feedback.delete.doesNotCreateTombstone",
                    expected: "no tombstone",
                    actual: tombstone == nil ? "missing" : "exists"
                )
                if let original {
                    let recreated = try await repository.upsert(
                        original,
                        observationKey: "\(HoloMemorySimulatorValidationFixtures.namespace)-delete-recreate"
                    )
                    recorder.check(
                        recreated == .inserted,
                        name: "feedback.delete.allowsFutureRecreation",
                        expected: "inserted",
                        actual: String(describing: recreated)
                    )
                }
            }

            let allowedQuery = HoloMemoryQueryService(
                store: repository,
                answeringAllowed: { _ in true },
                refreshCoordinator: HoloMemoryRefreshCoordinator { _ in }
            )
            let holistic = try await allowedQuery.query(
                question: "我最近状态如何",
                consumer: .analysis,
                now: now
            )
            queryResults.append(makeQueryResult(question: "我最近状态如何", context: holistic))
            recorder.check(
                holistic.route == .holisticMemory &&
                    !holistic.requiresDetailData &&
                    holistic.records.contains(where: { $0.scope == .crossDomain }),
                name: "query.holistic.selectsCrossDomainMemory",
                expected: "holistic/no fallback/cross-domain selected",
                actual: "route=\(holistic.route.rawValue),fallback=\(holistic.requiresDetailData),ids=\(holistic.records.map(\.id))"
            )

            let finance = try await allowedQuery.query(
                question: "我的财务状态怎么样",
                consumer: .analysis,
                now: now
            )
            queryResults.append(makeQueryResult(question: "我的财务状态怎么样", context: finance))
            recorder.check(
                finance.route == .domainMemory &&
                    !finance.requiresDetailData &&
                    !finance.records.isEmpty &&
                    finance.records.allSatisfy { $0.primaryDomain == .finance },
                name: "query.domain.selectsFinanceOnly",
                expected: "domain/no fallback/finance active IDs",
                actual: "route=\(finance.route.rawValue),fallback=\(finance.requiresDetailData),domains=\(finance.records.compactMap(\.primaryDomain).map(\.rawValue))"
            )

            let health = try await allowedQuery.query(
                question: "我的健康状态怎么样",
                consumer: .analysis,
                now: now
            )
            queryResults.append(makeQueryResult(question: "我的健康状态怎么样", context: health))
            recorder.check(
                health.records.allSatisfy { $0.id != recordIDs[.healthCandidate] },
                name: "query.pendingHealthNeverEntersAnswer",
                expected: "pending health ID absent",
                actual: "ids=\(health.records.map(\.id))"
            )

            let detail = try await allowedQuery.query(
                question: "最近14天吃了多少麦当劳",
                consumer: .analysis,
                now: now
            )
            queryResults.append(makeQueryResult(question: "最近14天吃了多少麦当劳", context: detail))
            recorder.check(
                detail.route == .detail &&
                    detail.requiresDetailData &&
                    detail.answerAuthority == .backgroundOnly,
                name: "query.detail.requiresAuthoritativeData",
                expected: "detail/fallback/backgroundOnly",
                actual: "route=\(detail.route.rawValue),fallback=\(detail.requiresDetailData),authority=\(detail.answerAuthority.rawValue)"
            )
            let detailEnvelope = HoloMemoryContextEnvelope.render(detail)
            recorder.check(
                detailEnvelope.contains("需要查询明细") &&
                    detailEnvelope.contains("不能提供金额、次数或精确统计"),
                name: "context.detail.prohibitsExactAnswerFromMemory",
                expected: "detail boundary rule present",
                actual: detailEnvelope
            )

            let disabledQuery = HoloMemoryQueryService(
                store: repository,
                answeringAllowed: { _ in false },
                refreshCoordinator: HoloMemoryRefreshCoordinator { _ in }
            )
            let disabled = try await disabledQuery.query(
                question: "我最近状态如何",
                consumer: .analysis,
                now: now
            )
            recorder.check(
                disabled.records.isEmpty &&
                    disabled.refreshDecision == .disabled &&
                    HoloMemoryContextEnvelope.render(disabled).isEmpty,
                name: "query.disabled.returnsNoMemoryOrContext",
                expected: "0 IDs/disabled/empty context",
                actual: "ids=\(disabled.records.count),refresh=\(String(describing: disabled.refreshDecision)),context=\(HoloMemoryContextEnvelope.render(disabled).count)"
            )

            let activeIDs = Set(try await repository.query(.active)
                .filter { $0.state == .active }
                .map(\.id))
            let forbiddenIDs = [
                recordIDs[.healthCandidate],
                historicalCandidate.id
            ].compactMap { $0 }
            recorder.check(
                forbiddenIDs.allSatisfy { !activeIDs.contains($0) } &&
                    queryResults.allSatisfy { result in
                        Set(result.selectedMemoryIDs).isDisjoint(with: forbiddenIDs)
                    },
                name: "query.excludesPendingAndArchived",
                expected: "pending/archived IDs absent",
                actual: "active=\(activeIDs.sorted()),forbidden=\(forbiddenIDs)"
            )

            let inbox = await HoloMemoryReceiptStore.inboxSnapshot()
            recorder.check(
                inbox.newMemoryCount >= 1 &&
                    inbox.pendingConfirmationCount == 1 &&
                    inbox.hasUnreadMigrationSummary,
                name: "receipt.summaryAggregatesNewPendingAndMigration",
                expected: "new>=1/pending=1/migration unread",
                actual: "new=\(inbox.newMemoryCount),pending=\(inbox.pendingConfirmationCount),migration=\(inbox.hasUnreadMigrationSummary)"
            )
            let presentedAt = now.addingTimeInterval(20)
            HoloMemoryReceiptStore.markSummaryPresented(now: presentedAt)
            recorder.check(
                !HoloMemoryReceiptStore.shouldPresentSummary(
                    now: presentedAt.addingTimeInterval(3_600)
                ) && HoloMemoryReceiptStore.shouldPresentSummary(
                    now: presentedAt.addingTimeInterval(25 * 3_600)
                ),
                name: "receipt.summaryAtMostOncePer24Hours",
                expected: "hidden at +1h/allowed at +25h",
                actual: "oneHour=\(HoloMemoryReceiptStore.shouldPresentSummary(now: presentedAt.addingTimeInterval(3_600))),twentyFiveHours=\(HoloMemoryReceiptStore.shouldPresentSummary(now: presentedAt.addingTimeInterval(25 * 3_600)))"
            )

            try writeReport(
                environment: environment,
                report: makeReport(
                    startedAt: startedAt,
                    completedAt: Date(),
                    recorder: recorder,
                    records: try await repository.query(.all),
                    queryResults: queryResults
                )
            )
        } catch {
            recorder.check(
                false,
                name: "scenario.unhandledError",
                expected: "no error",
                actual: String(describing: error)
            )
            let report = HoloMemorySimulatorValidationReport(
                scenario: environment.scenario,
                startedAt: startedAt,
                completedAt: Date(),
                status: "failed",
                assertions: recorder.assertions,
                recordStates: [:],
                queryResults: queryResults
            )
            try? writeReport(environment: environment, report: report)
            logger.error("模拟器记忆验收失败：\(String(describing: error), privacy: .public)")
        }
        return true
    }

    private static func expectedInitialState(
        for role: HoloMemorySimulatorValidationFixtureRole
    ) -> HoloMemoryState {
        switch role {
        case .healthCandidate: .candidate
        case .financeActive, .habitActive, .correctionActive, .rejectionActive, .deletionActive:
            .active
        }
    }

    private static func makeQueryResult(
        question: String,
        context: HoloMemoryQueryContext
    ) -> HoloMemorySimulatorValidationQueryResult {
        HoloMemorySimulatorValidationQueryResult(
            question: question,
            route: context.route.rawValue,
            authority: context.answerAuthority.rawValue,
            requiresDetailData: context.requiresDetailData,
            selectedMemoryIDs: context.records.map(\.id),
            renderedContext: HoloMemoryContextEnvelope.render(context)
        )
    }

    private static func makeReport(
        startedAt: Date,
        completedAt: Date,
        recorder: AssertionRecorder,
        records: [HoloMemoryRecord],
        queryResults: [HoloMemorySimulatorValidationQueryResult]
    ) -> HoloMemorySimulatorValidationReport {
        HoloMemorySimulatorValidationReport(
            scenario: HoloMemorySimulatorValidationEnvironment.supportedScenario,
            startedAt: startedAt,
            completedAt: completedAt,
            status: recorder.assertions.allSatisfy(\.passed) ? "passed" : "failed",
            assertions: recorder.assertions,
            recordStates: Dictionary(uniqueKeysWithValues: records.map {
                ($0.id, "\($0.state.rawValue)/\($0.userDecision.rawValue)/v\($0.recordVersion)")
            }),
            queryResults: queryResults
        )
    }

    private static func writeReport(
        environment: HoloMemorySimulatorValidationEnvironment,
        report: HoloMemorySimulatorValidationReport
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: environment.reportURL, options: .atomic)
        logger.info(
            "模拟器记忆验收完成：status=\(report.status, privacy: .public), failed=\(report.failedAssertionCount, privacy: .public)"
        )
    }

    private final class SimulatorMigrationStateStore: HoloMemoryMigrationStateStore,
        @unchecked Sendable {
        var completedVersion = 0
    }

    private struct AssertionRecorder {
        var assertions: [HoloMemorySimulatorValidationAssertion] = []

        mutating func check(
            _ passed: Bool,
            name: String,
            expected: String,
            actual: String
        ) {
            assertions.append(HoloMemorySimulatorValidationAssertion(
                name: name,
                passed: passed,
                expected: expected,
                actual: actual
            ))
        }
    }
}
#endif
#endif
