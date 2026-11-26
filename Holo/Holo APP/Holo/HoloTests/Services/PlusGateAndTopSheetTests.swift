//
//  PlusGateAndTopSheetTests.swift
//  HoloTests
//
//  2026-11-24 东林实报三连的回归锁定：
//  ① 已开通 Plus 却处处弹付费墙 → 冷启动空窗期（本进程权益刷新未落定）门禁不拿旧快照拦会员
//  ② 关掉 Plus 页还继续打开页面 → 关闭 = 放弃；购买成功才续接，且等付费墙收起后
//  ③ 截图记账确认页 / Plus 页被别的弹层挡住 → 置顶弹层盖在已开弹层之上，底下的弹层不动
//
//  权益单例用「验收来源」的状态写入：验收态不落盘，不污染测试宿主的权益快照。
//

import SwiftUI
import XCTest
@testable import Holo
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Plus 门禁

@MainActor
final class HoloPlusGateTests: XCTestCase {

    /// 续接动作的探针（闭包要在 Task 里跑，用引用类型避免捕获可变局部变量）
    private final class Probe {
        var resumed = false
    }

    private let entitlement = HoloEntitlementState.shared
    private let coordinator = HoloPlusActionCoordinator.shared

    override func tearDown() async throws {
        coordinator.dismissPaywall()
        coordinator.paywallDidDismiss()
        applyEntitlement(isPlus: false)
        DeepLinkState.shared.pendingTarget = nil
        try await super.tearDown()
    }

    // MARK: 辅助

    private func applyEntitlement(isPlus: Bool) {
        entitlement.apply(status: HoloSubscriptionStatusResponse(
            tier: isPlus ? "plus" : "free",
            isPlusActive: isPlus,
            productId: nil,
            expiresAt: nil,
            products: .init(plusMonthly: "plus.monthly", plusYearly: "plus.yearly"),
            quotas: [:],
            source: "acceptance",
            acceptanceMode: isPlus ? "plus" : "free",
            featureFlags: nil
        ))
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: 关闭 = 放弃

    func testClosingPaywallWithoutPurchaseDoesNotResume() async throws {
        applyEntitlement(isPlus: false)
        entitlement.markStatusAttemptFinished()
        let probe = Probe()
        coordinator.requirePlus(context: .habitPause, resume: { probe.resumed = true })
        XCTAssertTrue(coordinator.isPaywallPresented)

        coordinator.dismissPaywall()
        coordinator.paywallDidDismiss()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(coordinator.isPaywallPresented)
        XCTAssertFalse(probe.resumed, "未购买直接关闭：不应续做原操作")
    }

    func testPurchaseResumesOnlyAfterPaywallDismissalFinishes() async throws {
        applyEntitlement(isPlus: false)
        entitlement.markStatusAttemptFinished()
        let probe = Probe()
        coordinator.requirePlus(context: .habitPause, resume: { probe.resumed = true })

        await coordinator.resumeAfterSuccessfulPurchase()
        XCTAssertFalse(coordinator.isPaywallPresented)
        XCTAssertFalse(probe.resumed, "付费墙还在收起动画里：续接动作必须等收起之后")

        coordinator.paywallDidDismiss()
        try await waitUntil { probe.resumed }
        XCTAssertTrue(probe.resumed)
    }

    // MARK: 冷启动空窗期

    func testGateWaitsForFirstStatusAndResumesWhenServerSaysPlus() async throws {
        applyEntitlement(isPlus: false)
        entitlement.hasSettledStatus = false
        let probe = Probe()

        coordinator.requirePlus(context: .habitPause, resume: { probe.resumed = true })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(coordinator.isPaywallPresented, "刷新未落定：不拿旧快照的免费态弹付费墙")
        XCTAssertFalse(probe.resumed)

        // 刷新带回会员身份
        applyEntitlement(isPlus: true)
        entitlement.markStatusAttemptFinished()
        try await waitUntil { probe.resumed }

        XCTAssertTrue(probe.resumed, "会员应直接续做原操作")
        XCTAssertFalse(coordinator.isPaywallPresented, "会员不该看到付费墙")
    }

    func testGateShowsPaywallOnceFirstStatusConfirmsFree() async throws {
        applyEntitlement(isPlus: false)
        entitlement.hasSettledStatus = false
        let probe = Probe()

        coordinator.requirePlus(context: .habitPause, resume: { probe.resumed = true })
        entitlement.markStatusAttemptFinished()
        try await waitUntil { coordinator.isPaywallPresented }

        XCTAssertTrue(coordinator.isPaywallPresented, "刷新确认免费后才弹付费墙")
        XCTAssertFalse(probe.resumed)
    }

    // MARK: 小组件深链

    func testWidgetDeepLinkDoesNotNavigateAfterClosingPaywall() async throws {
        applyEntitlement(isPlus: false)
        entitlement.markStatusAttemptFinished()
        let url = try XCTUnwrap(URL(string: "holo://tasks"))

        DeepLinkState.shared.handle(url: url)
        XCTAssertTrue(coordinator.isPaywallPresented)

        coordinator.dismissPaywall()
        coordinator.paywallDidDismiss()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertNil(DeepLinkState.shared.pendingTarget, "关掉 Plus 页 = 放弃：不跳小组件指向的页面")
    }

    func testWidgetDeepLinkNavigatesDirectlyForPlusMember() async throws {
        applyEntitlement(isPlus: true)
        entitlement.markStatusAttemptFinished()
        let url = try XCTUnwrap(URL(string: "holo://tasks"))

        DeepLinkState.shared.handle(url: url)

        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .tasks)
        XCTAssertFalse(coordinator.isPaywallPresented)
    }

    func testWidgetDeepLinkOnColdStartDoesNotShowPaywallToPlusMember() async throws {
        // 点小组件拉起 App = 冷启动深链：此刻权益刷新还没落定，内存里是旧快照的免费态
        applyEntitlement(isPlus: false)
        entitlement.hasSettledStatus = false
        let url = try XCTUnwrap(URL(string: "holo://tasks"))

        DeepLinkState.shared.handle(url: url)
        XCTAssertFalse(coordinator.isPaywallPresented)

        applyEntitlement(isPlus: true)
        entitlement.markStatusAttemptFinished()
        try await waitUntil { DeepLinkState.shared.pendingTarget == .tasks }

        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .tasks)
        XCTAssertFalse(coordinator.isPaywallPresented, "会员冷启动点小组件不该先看到付费墙")
    }

    // MARK: 场景化付费墙与权益表对齐

    func testPaywallPresentationHighlightsDeepAnalysis1PerDay() {
        let presentation = HoloPlusPaywallPresentation.make(for: .deepAnalysis)
        XCTAssertEqual(presentation.items.count, 4)
        XCTAssertTrue(presentation.items[0].isFeatured)
        XCTAssertTrue(presentation.items[0].title.contains("1 次"))
        XCTAssertTrue(presentation.items[0].title.contains("10 次"))
        // 去重校验：后续 3 条不应重复出现同类别
        let trailingAxes = presentation.items.dropFirst().map(\.axis)
        XCTAssertFalse(trailingAxes.contains(presentation.items[0].axis))
    }

    func testPaywallPresentationHighlightsFinanceForBudgetGate() {
        let presentation = HoloPlusPaywallPresentation.make(for: .budget)
        XCTAssertEqual(presentation.items.count, 4)
        XCTAssertTrue(presentation.items[0].isFeatured)
        XCTAssertEqual(presentation.items[0].axis, .finance)
        XCTAssertTrue(presentation.items[0].title.contains("预算"))
    }

    func testBenefitComparisonTableAlignsWithDeepAnalysisAndAllLocalGates() {
        let all = HoloPlusBenefits.all
        let deepAnalysis = all.first { $0.name == "深度洞察" }
        XCTAssertEqual(deepAnalysis?.freeValue, .text("1 次/天"))
        XCTAssertEqual(deepAnalysis?.plusValue, .text("10 次/天"))

        let requiredNames = ["账单智能导入", "预算管理", "财务分期", "自定义账单周期", "信用卡还款提醒", "习惯补签"]
        for name in requiredNames {
            XCTAssertTrue(all.contains { $0.name == name }, "完整权益表漏掉了实际拦截项：\(name)")
        }
    }
}

// MARK: - 置顶弹层

#if canImport(UIKit)
@MainActor
final class HoloTopSheetPresenterTests: XCTestCase {

    private struct Ticket: Identifiable, Equatable {
        let id: String

        init(_ id: String) { self.id = id }
    }

    private var window: UIWindow!
    private var root: UIViewController!
    /// 「挡路」的弹层：模拟用户正开着的页面
    private var blocker: UIViewController!
    private var presenter: HoloTopSheetPresenter<Ticket, Text>!
    private var item: Ticket?
    private var dismissCount = 0

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()

        presenter = HoloTopSheetPresenter<Ticket, Text>()
        root.addChild(presenter)
        root.view.addSubview(presenter.view)
        presenter.didMove(toParent: root)
        // 先空跑一次：让协调器记下宿主窗口（被全屏页盖住后 view.window 会变 nil）
        sync()
        dismissCount = 0
    }

    override func tearDown() async throws {
        presenter.abort()
        root.dismiss(animated: false)
        window.isHidden = true
        window = nil
        root = nil
        blocker = nil
        presenter = nil
    }

    // MARK: 辅助

    private func sync() {
        presenter.sync(
            item: item,
            style: .sheet,
            binding: Binding(
                get: { [unowned self] in self.item },
                set: { [unowned self] in self.item = $0 }
            ),
            onDismiss: { [unowned self] in self.dismissCount += 1 },
            content: { ticket in Text("置顶页 \(ticket.id)") }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeBlocker() {
        blocker = UIViewController()
        blocker.view.backgroundColor = .red
    }

    // MARK: 用例

    /// 等置顶页真正弹出并呈现落定（转场中的请求会排到下一拍，断言前必须等）
    private func waitUntilPresented() async throws -> HoloTopSheetHost<HoloTopSheetPage<Text>> {
        try await waitUntil(timeout: 5) { [weak self] in
            self?.presenter.hosted?.hasAppeared == true
        }
        return try XCTUnwrap(presenter.hosted, "置顶页没有弹出来")
    }

    func testPresentsAboveAlreadyOpenSheetAndKeepsItAfterDismissal() async throws {
        makeBlocker()
        root.present(blocker, animated: false)

        item = Ticket("a")
        sync()
        let host = try await waitUntilPresented()

        XCTAssertTrue(host.presentingViewController === blocker, "应从最顶层（挡路弹层）发起呈现")
        XCTAssertTrue(blocker.presentedViewController === host)

        item = nil
        sync()
        try await waitUntil { [weak self] in self?.presenter.hosted == nil }

        XCTAssertNil(presenter.hosted)
        XCTAssertEqual(dismissCount, 1, "收起动画落定后回调一次")
        XCTAssertTrue(root.presentedViewController === blocker, "底下的页面原样保留")
    }

    func testCloseFromPageDismissesAndSyncsItemBackToNil() async throws {
        makeBlocker()
        root.present(blocker, animated: false)
        item = Ticket("a")
        sync()
        let host = try await waitUntilPresented()

        host.rootView.close()

        try await waitUntil { [weak self] in self?.presenter.hosted == nil }
        XCTAssertNil(item, "页内关闭后 item 同步回空")
        XCTAssertEqual(dismissCount, 1)
        XCTAssertTrue(root.presentedViewController === blocker)
    }

    func testSwappingItemUpdatesPageInPlace() async throws {
        makeBlocker()
        root.present(blocker, animated: false)
        item = Ticket("a")
        sync()
        let first = try await waitUntilPresented()

        item = Ticket("b")
        sync()

        XCTAssertTrue(presenter.hosted === first, "开着期间换内容：不收不重弹")
        XCTAssertTrue(blocker.presentedViewController === first)
        XCTAssertEqual(dismissCount, 0)

        item = nil
    }

    func testRequestArrivingWhilePreviousPageIsDismissingQueuesUp() async throws {
        makeBlocker()
        root.present(blocker, animated: false)
        item = Ticket("a")
        sync()
        let first = try await waitUntilPresented()

        // 程序侧关掉 a，收起动画还没落定就来了 b
        item = nil
        sync()
        item = Ticket("b")
        sync()

        try await waitUntil(timeout: 5) { [weak self] in
            guard let presenter = self?.presenter, let hosted = presenter.hosted else { return false }
            return hosted !== first && hosted.hasAppeared
        }
        let second = try XCTUnwrap(presenter.hosted, "旧页收起后应接着弹出排着队的新页")
        XCTAssertEqual(item, Ticket("b"), "旧页的收尾不能把排着队的新页清掉")
        XCTAssertEqual(dismissCount, 1, "旧页收起只回调一次")
        XCTAssertTrue(second.presentingViewController === blocker)
        XCTAssertTrue(blocker.presentedViewController === second)

        item = nil
    }

    func testDismissRequestedDuringPresentationHappensAfterItSettles() async throws {
        // 页面还在弹出动画里就被要求关闭：请求不能丢，等弹出落定后收起并回调
        makeBlocker()
        root.present(blocker, animated: false)
        item = Ticket("a")
        sync()
        // 等置顶页发起呈现（此刻还在弹出动画里、尚未落定）
        try await waitUntil { [weak self] in self?.presenter.hosted != nil }
        XCTAssertFalse(presenter.hosted?.hasAppeared ?? true, "场景前提：置顶页还在弹出动画里")
        item = nil
        sync()

        try await waitUntil(timeout: 5) { [weak self] in
            self?.presenter.hosted == nil && self?.dismissCount == 1
        }
        XCTAssertNil(presenter.hosted, "弹出落定后应收起")
        XCTAssertEqual(dismissCount, 1, "收起后回调一次")
        XCTAssertTrue(root.presentedViewController === blocker, "底下的页面原样保留")
    }

    func testUserSwipeDismissalDoesNotRequeueTheSamePage() async throws {
        // 用户下滑收起时 owner 不知情、item 没变；期间若 SwiftUI 重算触发了 sync，同一页不能被排回去重弹
        makeBlocker()
        root.present(blocker, animated: false)
        item = Ticket("a")
        sync()
        let host = try await waitUntilPresented()

        host.dismiss(animated: true)
        sync()

        try await waitUntil { [weak self] in self?.presenter.hosted == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(presenter.hosted, "下滑关闭后不应重弹")
        XCTAssertNil(item, "用户关闭后 item 同步回空")
        XCTAssertEqual(dismissCount, 1)
    }

    func testRequestBeforePresenterIsInWindowIsPresentedOnceItAppears() async throws {
        // 冷启动首帧之前就来了请求（如启动即到的截图记账深链）：不能丢，进窗口后再弹
        let late = HoloTopSheetPresenter<Ticket, Text>()
        item = Ticket("a")
        late.sync(
            item: item,
            style: .sheet,
            binding: Binding(get: { [unowned self] in self.item },
                             set: { [unowned self] in self.item = $0 }),
            onDismiss: { [unowned self] in self.dismissCount += 1 },
            content: { ticket in Text("置顶页 \(ticket.id)") }
        )
        XCTAssertNil(late.hosted, "还没进窗口：此刻弹不出来")

        root.addChild(late)
        root.view.addSubview(late.view)
        late.didMove(toParent: root)

        XCTAssertNotNil(late.hosted, "进窗口后要把排着的请求弹出来")
        XCTAssertTrue(late.hosted?.presentingViewController === root)
        late.abort()
        item = nil
    }

    func testRequestDuringInFlightPresentationIsNotDropped() async throws {
        // 挡路页正在弹出（转场未落定）时请求置顶页：不能被 UIKit 丢弃
        makeBlocker()
        root.present(blocker, animated: true)
        item = Ticket("a")
        sync()

        let host = try await waitUntilPresented()
        XCTAssertTrue(host.presentingViewController === blocker, "转场中发起的呈现不能丢")

        item = nil
    }
}
#endif
