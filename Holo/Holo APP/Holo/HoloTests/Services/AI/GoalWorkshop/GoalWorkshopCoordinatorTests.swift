//
//  GoalWorkshopCoordinatorTests.swift
//  HoloTests
//
//  目标共创编排器测试（方案任务 4）：零追问直达、两路线取舍、用户纠正、
//  网络失败可恢复、失败退预算（不占额度是产品决策）、模型非法输出与受控重试、
//  重复提交防护、请求预算、跳过流。
//  注：GoalWorkshopCoordinator 不引用 ChatViewModel/GoalPlanningSession（结构上
//  与旧 activeGoalPlanningSession 隔离），不进入旧流程是编译期保证。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalWorkshopCoordinatorTests: XCTestCase {

    // MARK: - 假模型服务

    final class FakeService: GoalWorkshopModelServicing, @unchecked Sendable {
        enum Step {
            case ok(String)
            case okEcho((UUID, Int) -> String)
            case fail(Error)
        }
        private let lock = NSLock()
        private var steps: [Step] = []
        private(set) var requestBodies: [String] = []
        /// 下一次调用挂起（测重复提交用）
        var holdNext: Bool = false
        private var heldContinuation: CheckedContinuation<String, Error>?

        func enqueue(_ step: Step) {
            lock.lock(); defer { lock.unlock() }
            steps.append(step)
        }

        func releaseHeld(_ result: Result<String, Error>) {
            lock.lock(); defer { lock.unlock() }
            heldContinuation?.resume(with: result)
            heldContinuation = nil
        }

        /// 按挂起请求的 sessionID/revision 构建回显后释放（避免测试硬编码 revision）
        func releaseHeldEcho(_ builder: (UUID, Int) -> String) {
            lock.lock()
            let body = requestBodies.last ?? "{}"
            lock.unlock()
            let (sessionID, revision) = Self.parseIdentity(body)
            releaseHeld(.success(builder(sessionID, revision)))
        }

        func sendGoalWorkshop(_ bodyJSON: String) async throws -> String {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                lock.lock()
                requestBodies.append(bodyJSON)
                if holdNext {
                    holdNext = false
                    heldContinuation = continuation
                    lock.unlock()
                    return
                }
                let step = steps.isEmpty ? Step.fail(URLError(.badServerResponse)) : steps.removeFirst()
                lock.unlock()
                continuation.resume(with: Result {
                    switch step {
                    case .ok(let text): return text
                    case .okEcho(let builder):
                        let (sessionID, revision) = Self.parseIdentity(bodyJSON)
                        return builder(sessionID, revision)
                    case .fail(let error): throw error
                    }
                })
            }
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return requestBodies.count
        }

        static func parseIdentity(_ body: String) -> (UUID, Int) {
            guard let data = body.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionIDString = object["sessionID"] as? String,
                  let sessionID = UUID(uuidString: sessionIDString),
                  let revision = object["revision"] as? Int else {
                return (UUID(), -1)
            }
            return (sessionID, revision)
        }
    }

    // MARK: - 响应工厂（回显请求 sessionID/revision）

    private static func questionJSON(sessionID: UUID, revision: Int) -> String {
        """
        {"schemaVersion":1,"sessionID":"\(sessionID.uuidString)","revision":\(revision),"kind":"question","assistantText":"先对齐一件事","question":{"text":"最近一场英文会议是什么时候？","whyItMatters":"频率决定路径"},"options":null,"recommendedOptionID":null,"plan":null,"facts":[{"id":"f-1","text":"推断：有真实场景","provenance":"inference"}]}
        """
    }

    private static func optionsJSON(sessionID: UUID, revision: Int) -> String {
        """
        {"schemaVersion":1,"sessionID":"\(sessionID.uuidString)","revision":\(revision),"kind":"options","assistantText":"两条路给你选","question":null,"options":[{"id":"route-1","title":"先练会议听说","fit":"近期有会","effort":"每天20分钟","tradeoff":"基础边用边补","reason":"贴近用途"},{"id":"route-2","title":"先补基础","fit":"近期无会","effort":"每天20分钟","tradeoff":"上手慢","reason":"先减障碍"}],"recommendedOptionID":"route-1","plan":null,"facts":null}
        """
    }

    private static func planJSON(sessionID: UUID, revision: Int) -> String {
        """
        {"schemaVersion":1,"sessionID":"\(sessionID.uuidString)","revision":\(revision),"kind":"plan","assistantText":"初稿好了","question":null,"options":null,"recommendedOptionID":null,"plan":{"draft":{"id":"draft-1","title":"工作会议英语敢开口","summary":null,"domain":"learning","iconEmoji":null,"desiredOutcome":"周会发言一次","motivation":null,"deadlineText":"2026-12-31","tasks":[{"id":"task-1","isSelected":true,"title":"准备英文自我介绍","dueDateText":"2026-09-25","priority":1,"note":null}],"habits":[{"id":"habit-1","isSelected":true,"name":"跟读会议录音","frequency":"daily","targetCount":1,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"}],"missingInfoWarnings":[]},"successEvidence":"连续四周周会发言","milestones":[{"id":"m-1","title":"首次英文发言","dateText":"2026-10-31"}],"firstActionID":"task-1","assumptions":["每周有英文会"],"reviewDate":"2026-10-15"},"facts":null}
        """
    }

    // MARK: - 环境

    private var context: NSManagedObjectContext!
    private var store: GoalWorkshopStore!
    private var service: FakeService!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["GoalWorkshopSessionMO", "GoalPlanRevisionMO"])
        store = GoalWorkshopStore(context: context)
        service = FakeService()
        CoreDataTestSupport.retain(store)
    }

    private func makeCoordinator() -> GoalWorkshopCoordinator {
        // 产品决策（2026-09-19）：共创不占对话额度，协调器不再有额度预检/闸门
        GoalWorkshopCoordinator(service: service, store: store)
    }

    // MARK: - 用例

    func testZeroQuestionDirectPathToReviewing() async throws {
        let coordinator = makeCoordinator()
        // 模型认为信息足够：首轮直接给路径（零追问）
        service.enqueue(.okEcho { Self.optionsJSON(sessionID: $0, revision: $1) })
        var session = try await coordinator.start(seedText: "我想在工作会议中更敢开口说英语")

        XCTAssertEqual(session.phase, .exploring)
        XCTAssertEqual(session.questionsAsked, 0, "零追问直达路径")
        XCTAssertEqual(session.routeOptions.count, 2)

        session = try await coordinator.choose(sessionID: session.id, optionID: "route-2")
        XCTAssertEqual(session.selectedRouteID, "route-2", "用户可选非推荐路线")
        service.enqueue(.okEcho { Self.planJSON(sessionID: $0, revision: $1) })
        session = try await coordinator.generatePlan(sessionID: session.id)
        XCTAssertEqual(session.phase, .reviewing)
        XCTAssertEqual(session.plan?.firstActionID, "task-1")
        XCTAssertEqual(session.requestCount, 2)
    }

    func testQuestionReplyLoopWithUserCorrection() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        var session = try await coordinator.start(seedText: "想重新捡起日语")
        XCTAssertEqual(session.phase, .understanding)
        XCTAssertEqual(session.currentQuestion?.text.contains("会议") ?? false, true)

        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        session = try await coordinator.reply(sessionID: session.id, text: "每天晚上有两小时空闲")
        XCTAssertEqual(session.facts.filter { $0.provenance == .userStated }.count, 1)

        guard let factID = session.facts.first(where: { $0.provenance == .userStated })?.id else {
            return XCTFail("应有可纠正的 userStated 事实")
        }
        session = try await coordinator.correctFact(sessionID: session.id, factID: factID,
                                                    text: "不是没时间，是坐下来就不想练")
        XCTAssertEqual(session.facts.first { $0.id == factID }?.isRetracted, true, "旧陈述撤回留痕")
        XCTAssertTrue(session.activeFacts.contains { $0.text.contains("不想练") })
    }

    func testNetworkFailureKeepsSessionRecoverable() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")

        service.enqueue(.fail(URLError(.notConnectedToInternet)))
        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "一年读完 12 本")
            XCTFail("网络失败应抛错")
        } catch {}

        // 会话保留：用户回答已落库、阶段未变，可重试续走
        let recovered = try await coordinator.loadSession(session.id)
        XCTAssertEqual(recovered.facts.filter { $0.provenance == .userStated }.count, 1)
        XCTAssertEqual(recovered.phase, .understanding)

        service.enqueue(.okEcho { Self.optionsJSON(sessionID: $0, revision: $1) })
        let next = try await coordinator.reply(sessionID: session.id, text: "再来一次")
        XCTAssertEqual(next.phase, .exploring, "失败后可恢复续走")
    }

    func testQuotaGuardsRemovedByProductDecision() async throws {
        // 产品决策（2026-09-19）：共创不占额度、免费全量开放——
        // 旧的「开始前预检/过程中额度拦截」已删除；对话额度归零也不得拦截共创
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想变好")
        XCTAssertEqual(session.phase, .understanding, "无额度闸门：直接开跑")
    }

    func testFailedRequestRefundsBudget() async throws {
        // 预算是保险丝不是计费器：没拿到结果的轮次必须退款，会话不能因失败卡死
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")
        let before = try await coordinator.loadSession(session.id)

        // 网络失败：退款
        service.enqueue(.fail(URLError(.notConnectedToInternet)))
        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "一年读完 12 本")
            XCTFail("网络失败应抛错")
        } catch {}
        let afterTransport = try await coordinator.loadSession(session.id)
        XCTAssertEqual(afterTransport.requestCount, before.requestCount, "传输失败应退预算")

        // 连续非法输出：同样退款
        service.enqueue(.ok("garbage"))
        service.enqueue(.ok("still garbage"))
        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "再答")
            XCTFail("连续非法输出应报错")
        } catch let error as GoalWorkshopCoordinatorError {
            guard case .invalidModelOutput = error else {
                return XCTFail("应抛 invalidModelOutput：\(error)")
            }
        }
        let afterInvalid = try await coordinator.loadSession(session.id)
        XCTAssertEqual(afterInvalid.requestCount, before.requestCount, "非法输出终败应退预算")
        XCTAssertEqual(afterInvalid.phase, before.phase, "失败不得回退阶段")
    }

    func testInvalidModelOutputRetriesOnceThenFails() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")

        // 第一轮非法（围栏包裹的坏 JSON），受控重试给合法 options
        service.enqueue(.ok("```json\n{not valid json}\n```"))
        service.enqueue(.okEcho { Self.optionsJSON(sessionID: $0, revision: $1) })
        let recovered = try await coordinator.reply(sessionID: session.id, text: "按本数来")
        XCTAssertEqual(recovered.phase, .exploring, "一次受控重试后恢复")

        // 连续非法：首答+重试都坏 → invalidModelOutput，会话保留并记录失败
        service.enqueue(.ok("garbage"))
        service.enqueue(.ok("still garbage"))
        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "再答")
            XCTFail("连续非法输出应报错")
        } catch let error as GoalWorkshopCoordinatorError {
            guard case .invalidModelOutput = error else {
                return XCTFail("应抛 invalidModelOutput：\(error)")
            }
        }
        let kept = try await coordinator.loadSession(session.id)
        XCTAssertNotNil(kept.lastModelFailureText, "失败原因应留在会话")
        XCTAssertEqual(kept.phase, .exploring, "失败不得回退阶段")
    }

    func testDuplicateSubmissionRejectedWhileInFlight() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")

        service.holdNext = true
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let first = Task { try await coordinator.reply(sessionID: session.id, text: "第一次") }
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "重复点击")
            XCTFail("在途重复提交应被拒")
        } catch let error as GoalWorkshopCoordinatorError {
            guard case .duplicateInFlight = error else {
                return XCTFail("应抛 duplicateInFlight：\(error)")
            }
        }

        service.releaseHeldEcho { Self.questionJSON(sessionID: $0, revision: $1) }
        let result = try await first.value
        XCTAssertEqual(result.phase, .understanding)
    }

    func testRequestBudgetExhaustionSurfaces() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")

        var maxed = try await coordinator.loadSession(session.id)
        while maxed.requestCount < GoalWorkshopBudget.maxModelRequests {
            try maxed.beginModelRequest()
        }
        try store.saveIfRevisionMatches(maxed)

        do {
            _ = try await coordinator.reply(sessionID: session.id, text: "再问")
            XCTFail("预算耗尽应报错")
        } catch let error as GoalWorkshopCoordinatorError {
            XCTAssertEqual(error, .requestBudgetExhausted)
        }
    }

    func testCancelRemovesSession() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        let session = try await coordinator.start(seedText: "想多读书")
        try await coordinator.cancel(sessionID: session.id)
        do {
            _ = try await coordinator.loadSession(session.id)
            XCTFail("取消后不应再能读取")
        } catch let error as GoalWorkshopCoordinatorError {
            XCTAssertEqual(error, .sessionUnavailable(session.id))
        }
    }

    func testSkipFlows() async throws {
        let coordinator = makeCoordinator()
        service.enqueue(.okEcho { Self.questionJSON(sessionID: $0, revision: $1) })
        var session = try await coordinator.start(seedText: "别问了直接给我计划")

        // understanding 跳过：标记后由 UI 发起 requestOptions
        session = try await coordinator.skip(sessionID: session.id)
        XCTAssertEqual(session.questioningSkipped, true)

        service.enqueue(.okEcho { Self.optionsJSON(sessionID: $0, revision: $1) })
        session = try await coordinator.requestOptions(sessionID: session.id)
        XCTAssertEqual(session.phase, .exploring)

        // exploring 跳过 = 接受推荐
        session = try await coordinator.skip(sessionID: session.id)
        XCTAssertEqual(session.selectedRouteID, "route-1")
        XCTAssertEqual(session.phase, .choosing)
    }
}

// MARK: - 发送路由决策（2026-09-19 深度分析被规划会话吞事故的回归锁）
//
// 事故：collecting 期规划会话无条件拦截全部输入，场景面板预填的深度分析问句
// 被吞成规划回答且无任何 UI 痕迹。修复后路由优先级 = 显式场景 > 规划续答 >
// 草案待确认 > 常规意图识别，决策矩阵在此锁定。

@MainActor
final class ChatSendRouteResolverTests: XCTestCase {

    private let finance = AnalysisScenario.finance

    func testExplicitScenarioTakesPriorityOverCollectingSession() {
        let route = ChatViewModel.resolveSendRoute(
            text: finance.question,
            explicitScenario: finance,
            planningStatus: .collecting,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .explicitDeepAnalysis(.finance))
    }

    func testEditedTextFallsBackToSessionRouting() {
        // 用户改写问句后不再享受确定性路由（与「可改写问句」来源提示口径一致），
        // 此时有规划会话则照旧被会话消费
        let route = ChatViewModel.resolveSendRoute(
            text: finance.question + "，谢谢",
            explicitScenario: finance,
            planningStatus: .collecting,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .goalPlanningReply)
    }

    func testLongTermPatternNeverRoutesExplicit() {
        // 长期模式是画像问答，不占分析额度，走普通意图识别
        let route = ChatViewModel.resolveSendRoute(
            text: AnalysisScenario.longTermPattern.question,
            explicitScenario: .longTermPattern,
            planningStatus: nil,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .regular)
    }

    func testCollectingSessionConsumesRegularText() {
        let route = ChatViewModel.resolveSendRoute(
            text: "帮我记一笔午饭 35 元",
            explicitScenario: nil,
            planningStatus: .collecting,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .goalPlanningReply)
    }

    func testDraftReadyYieldsPendingNotice() {
        let route = ChatViewModel.resolveSendRoute(
            text: "好",
            explicitScenario: nil,
            planningStatus: .draftReady,
            hasDraftForReview: true
        )
        XCTAssertEqual(route, .goalDraftPendingNotice)
    }

    func testRegularWhenNothingSpecial() {
        let route = ChatViewModel.resolveSendRoute(
            text: "今天天气不错",
            explicitScenario: nil,
            planningStatus: nil,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .regular)
    }
}
