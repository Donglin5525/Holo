//
//  DiscoveryAccessPolicyTests.swift
//  HoloTests
//
//  「一个发现」G1 门控纯逻辑测试：六检查位（读源前/candidates 前/verify 前/提交前/
//  展示前/续聊前）各 allow/deny 至少一例。默认关必 deny、总授权撤回必 deny、
//  范围不含某域时该域 deny。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
@testable import Holo

final class DiscoveryAccessPolicyTests: XCTestCase {

    private var now: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    private let policy = DiscoveryAccessPolicy()

    /// 环境工厂：默认即允许环境（总授权开、功能开 thought 域 epoch 1、控制代数 1、预算 1）
    private func environment(
        consent: Bool = true,
        enabled: Bool = true,
        domains: Set<DiscoverySourceDomain> = [.thought],
        epoch: Int = 1,
        controlRevision: Int? = 1,
        budget: Int = 1
    ) -> DiscoveryAccessSnapshot {
        var environment = DiscoveryAccessSnapshot()
        environment.now = now
        environment.isGlobalConsentGranted = consent
        environment.settings = DiscoverySettingsSnapshot(
            isEnabled: enabled,
            allowedDomains: domains,
            localGrantEpoch: epoch
        )
        environment.serverControlRevision = controlRevision
        environment.dailyAutoBatchBudgetRemaining = budget
        return environment
    }

    private func makeFreeze(
        epoch: Int = 1,
        controlRevision: Int = 1,
        scopeRevision: String = DiscoveryScopeRevision.digest(domains: [.thought])
    ) -> DiscoveryRunFreeze {
        DiscoveryRunFreeze(
            runID: "run-1",
            accountSubject: "device-subject-1",
            deviceID: "device-1",
            localGrantEpoch: epoch,
            serverControlRevision: controlRevision,
            scopeRevision: scopeRevision,
            sourceManifestDigest: "digest-1",
            candidatePromptVersion: 1,
            verifyPromptVersion: 1,
            modelRouteVersion: 1,
            policyVersion: 1,
            anchorNow: now,
            timezone: "Asia/Shanghai"
        )
    }

    private func makeFinding(
        status: DiscoveryFindingStatus = .published,
        expiresOffset: TimeInterval = 14 * 24 * 3600,
        rejected: Bool = false,
        dependenciesValid: Bool = true
    ) -> DiscoveryFindingDisplayState {
        DiscoveryFindingDisplayState(
            status: status,
            expiresAt: now.addingTimeInterval(expiresOffset),
            subjectNegativeFeedbackHit: rejected,
            dependenciesValid: dependenciesValid
        )
    }

    // MARK: - 检查位 1：读源前

    func test_读源前_默认关闭必拒() {
        let decision = policy.canReadSources(domain: .thought, environment: environment(enabled: false))
        XCTAssertEqual(decision.deniedReason, .featureDisabled)
        XCTAssertFalse(decision.isAllowed)
    }

    func test_读源前_总授权撤回必拒() {
        let decision = policy.canReadSources(domain: .thought, environment: environment(consent: false))
        XCTAssertEqual(decision.deniedReason, .globalConsentMissing)
    }

    func test_读源前_范围不含该域必拒_包含则允许() {
        // 范围只有 thought：habit 域拒
        XCTAssertEqual(
            policy.canReadSources(domain: .habit, environment: environment(domains: [.thought])).deniedReason,
            .domainNotGranted
        )
        // 扩大范围后 habit 允许
        XCTAssertTrue(
            policy.canReadSources(domain: .habit, environment: environment(domains: [.thought, .habit])).isAllowed
        )
        // 空范围拒
        XCTAssertEqual(
            policy.canReadSources(domain: .thought, environment: environment(domains: [])).deniedReason,
            .emptyScope
        )
    }

    // MARK: - 检查位 2：candidates 前

    func test_candidates前_允许组合() {
        XCTAssertTrue(policy.canRequestCandidates(
            frozenGrantEpoch: 1,
            environment: environment()
        ).isAllowed)
    }

    func test_candidates前_预算耗尽必拒() {
        XCTAssertEqual(
            policy.canRequestCandidates(frozenGrantEpoch: 1, environment: environment(budget: 0)).deniedReason,
            .budgetExhausted
        )
    }

    func test_candidates前_控制快照不可用必拒() {
        XCTAssertEqual(
            policy.canRequestCandidates(frozenGrantEpoch: 1, environment: environment(controlRevision: nil)).deniedReason,
            .serverControlUnavailable
        )
    }

    func test_candidates前_冻结代数过期必拒() {
        XCTAssertEqual(
            policy.canRequestCandidates(frozenGrantEpoch: 0, environment: environment(epoch: 1)).deniedReason,
            .grantEpochStale
        )
    }

    // MARK: - 检查位 3：verify 前

    func test_verify前_允许组合() {
        XCTAssertTrue(policy.canRequestVerification(
            runPhase: .preparing,
            frozenGrantEpoch: 1,
            environment: environment()
        ).isAllowed)
    }

    func test_verify前_阶段不符必拒() {
        XCTAssertEqual(
            policy.canRequestVerification(runPhase: .ready, frozenGrantEpoch: 1, environment: environment()).deniedReason,
            .runStateInvalid
        )
    }

    // MARK: - 检查位 4：提交前

    func test_提交前_允许组合() {
        XCTAssertTrue(policy.canCommit(
            freeze: makeFreeze(),
            allDisplayedClaimsSupported: true,
            environment: environment()
        ).isAllowed)
    }

    func test_提交前_控制代数变化必拒() {
        XCTAssertEqual(
            policy.canCommit(
                freeze: makeFreeze(controlRevision: 1),
                allDisplayedClaimsSupported: true,
                environment: environment(controlRevision: 2)
            ).deniedReason,
            .serverControlChanged
        )
    }

    func test_提交前_冻结代数过期必拒() {
        XCTAssertEqual(
            policy.canCommit(
                freeze: makeFreeze(epoch: 0),
                allDisplayedClaimsSupported: true,
                environment: environment(epoch: 1)
            ).deniedReason,
            .grantEpochStale
        )
    }

    func test_提交前_范围摘要变化必拒() {
        XCTAssertEqual(
            policy.canCommit(
                freeze: makeFreeze(scopeRevision: "stale-scope"),
                allDisplayedClaimsSupported: true,
                environment: environment()
            ).deniedReason,
            .scopeChanged
        )
    }

    func test_提交前_有显示句未supported必拒() {
        XCTAssertEqual(
            policy.canCommit(
                freeze: makeFreeze(),
                allDisplayedClaimsSupported: false,
                environment: environment()
            ).deniedReason,
            .verificationIncomplete
        )
    }

    // MARK: - 检查位 5：展示前

    func test_展示前_允许组合() {
        XCTAssertTrue(policy.canDisplay(
            finding: makeFinding(),
            environment: environment()
        ).isAllowed)
    }

    func test_展示前_过期必拒() {
        XCTAssertEqual(
            policy.canDisplay(finding: makeFinding(expiresOffset: -1), environment: environment()).deniedReason,
            .findingExpired
        )
    }

    func test_展示前_来源失效必拒() {
        XCTAssertEqual(
            policy.canDisplay(finding: makeFinding(dependenciesValid: false), environment: environment()).deniedReason,
            .sourceInvalidated
        )
    }

    func test_展示前_用户已否定必拒() {
        XCTAssertEqual(
            policy.canDisplay(finding: makeFinding(rejected: true), environment: environment()).deniedReason,
            .userRejected
        )
    }

    func test_展示前_无有效发现必拒() {
        XCTAssertEqual(
            policy.canDisplay(finding: makeFinding(status: .rejected), environment: environment()).deniedReason,
            .findingUnavailable
        )
        XCTAssertEqual(
            policy.canDisplay(finding: makeFinding(status: .invalidated), environment: environment()).deniedReason,
            .findingUnavailable
        )
    }

    // MARK: - 检查位 6：续聊前

    func test_续聊前_允许组合() {
        XCTAssertTrue(policy.canContinueConversation(
            finding: makeFinding(status: .viewed),
            environment: environment()
        ).isAllowed)
    }

    func test_续聊前_总授权撤回必拒() {
        XCTAssertEqual(
            policy.canContinueConversation(
                finding: makeFinding(),
                environment: environment(consent: false)
            ).deniedReason,
            .globalConsentMissing
        )
    }

    func test_续聊前_发现过期必拒() {
        XCTAssertEqual(
            policy.canContinueConversation(
                finding: makeFinding(expiresOffset: -1),
                environment: environment()
            ).deniedReason,
            .findingExpired
        )
    }

    // MARK: - 范围摘要

    func test_范围摘要_同集合同摘要_不同集合不同摘要() {
        let a = DiscoveryScopeRevision.digest(domains: [.thought, .task])
        let b = DiscoveryScopeRevision.digest(domains: [.task, .thought])
        let c = DiscoveryScopeRevision.digest(domains: [.thought])
        XCTAssertEqual(a, b, "摘要与域顺序无关")
        XCTAssertNotEqual(a, c, "范围变化必须改变摘要")
    }
}
