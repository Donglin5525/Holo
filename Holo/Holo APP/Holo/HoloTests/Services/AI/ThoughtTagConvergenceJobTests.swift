//
//  ThoughtTagConvergenceJobTests.swift
//  HoloTests
//
//  跨观点收敛任务状态机测试（P2.2）
//  覆盖 建议产出 / rateLimited / 重试耗尽 / 输入不足不调 AI / 空建议 / markdown fence / 已拒绝过滤
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class ThoughtTagConvergenceJobTests: XCTestCase {

    // MARK: - Scaffold

    private func makeContext() throws -> NSManagedObjectContext {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "ConvergenceJobTest", managedObjectModel: model)
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        var err: Error?
        container.loadPersistentStores { _, e in err = e }
        if let err { throw err }
        CoreDataTestSupport.retain(container, container.viewContext)
        return container.viewContext
    }

    private func makeJob(
        aiCall: @escaping ([ChatMessageDTO]) async throws -> String,
        ctx: NSManagedObjectContext,
        jobStore: ThoughtTagConvergenceJobStore? = nil
    ) -> ThoughtTagConvergenceJob {
        let isolatedStore = jobStore ?? ThoughtTagConvergenceJobStore(
            userDefaults: UserDefaults(suiteName: "ThoughtTagConvergenceJobTests.\(UUID().uuidString)")!
        )
        let job = ThoughtTagConvergenceJob(
            aiCall: aiCall,
            thoughtRepository: ThoughtRepository(context: ctx),
            topicRepository: TopicRepository(context: ctx),
            rejectionRepository: ConvergenceRejectionRepository(context: ctx),
            jobStore: isolatedStore,
            maxRetryCount: 2,
            retryIntervals: [0.01, 0.01]
        )
        CoreDataTestSupport.retain(job)
        return job
    }

    /// 灌一条带 .ai 标签的观点，返回 thoughtId
    @discardableResult
    private func seedThought(tag: String, ctx: NSManagedObjectContext) throws -> UUID {
        try seedThought(tags: [tag], ctx: ctx)
    }

    /// 灌一条带多个 .ai 标签的观点，返回 thoughtId
    @discardableResult
    private func seedThought(tags: [String], ctx: NSManagedObjectContext) throws -> UUID {
        let t = ctx.insertTestObject(Thought.self)
        t.id = UUID()
        t.content = "关于 \(tags.joined(separator: "、")) 的观点"
        t.createdAt = Date()
        t.updatedAt = Date()
        t.orderIndex = 0
        t.organizedStatus = "organized"

        for tag in tags {
            let tagEntity = ctx.insertTestObject(ThoughtTag.self)
            tagEntity.id = UUID()
            tagEntity.name = tag
            tagEntity.usageCount = 1

            let assignment = ctx.insertTestObject(ThoughtTagAssignment.self)
            assignment.id = UUID()
            assignment.source = ThoughtTagAssignment.Source.ai.rawValue
            assignment.confidence = 0.9
            assignment.assignedAt = Date()
            assignment.thought = t
            assignment.tag = tagEntity
        }

        try ctx.save()
        return t.id
    }

    // MARK: - 建议

    func test_AI返回建议_状态ready() async throws {
        let ctx = try makeContext()
        let id1 = try seedThought(tag: "coding", ctx: ctx)
        let id2 = try seedThought(tag: "coding", ctx: ctx)
        let id3 = try seedThought(tag: "coding", ctx: ctx)

        let raw = """
        {"suggestions":[{"topicTitle":"编程实践","matchedTopicId":null,"thoughtIds":["\(id1.uuidString)","\(id2.uuidString)","\(id3.uuidString)"],"sourceTerms":["coding"],"confidence":0.9,"reason":"三条都在谈编程"}]}
        """
        let job = makeJob(aiCall: { _ in raw }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.topicTitle, "编程实践")
        XCTAssertEqual(suggestions.first?.thoughtIds.count, 3)
        XCTAssertNil(suggestions.first?.matchedTopicId)
    }

    func test_AI返回空建议_有清晰重复标签时本地兜底出主题建议() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let job = makeJob(aiCall: { _ in "{\"suggestions\":[]}" }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.topicTitle, "coding")
        XCTAssertEqual(suggestions.first?.thoughtIds.count, 3)
        XCTAssertEqual(suggestions.first?.sourceTerms, ["coding"])
    }

    func test_AI返回空建议_重复标签不在首位时本地兜底仍能归纳() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tags: ["日常", "AI协作"], ctx: ctx)
        _ = try seedThought(tags: ["产品", "AI协作"], ctx: ctx)
        _ = try seedThought(tags: ["开发", "AI协作"], ctx: ctx)

        let job = makeJob(aiCall: { _ in "{\"suggestions\":[]}" }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.topicTitle, "AI协作")
        XCTAssertEqual(suggestions.first?.thoughtIds.count, 3)
    }

    func test_AI返回空建议_没有三条共享标签时不硬凑主题() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "product", ctx: ctx)
        _ = try seedThought(tag: "design", ctx: ctx)

        let job = makeJob(aiCall: { _ in "{\"suggestions\":[]}" }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - rateLimited

    func test_AI抛rateLimited_状态failed配额() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let job = makeJob(aiCall: { _ in throw APIError.rateLimited(nil) }, ctx: ctx)
        await job.run()

        guard case .failed(let message) = job.state else {
            return XCTFail("期望 failed，实际 \(job.state)")
        }
        XCTAssertTrue(message.contains("配额"))
    }

    // MARK: - 重试耗尽

    func test_AI抛serverError重试耗尽_状态failed() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let job = makeJob(aiCall: { _ in throw APIError.serverError("500") }, ctx: ctx)
        await job.run()

        guard case .failed = job.state else {
            return XCTFail("期望 failed（重试耗尽），实际 \(job.state)")
        }
    }

    func test_AI失败后重试成功_状态ready() async throws {
        let ctx = try makeContext()
        let id1 = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let raw = """
        {"suggestions":[{"topicTitle":"编程实践","matchedTopicId":null,"thoughtIds":["\(id1.uuidString)"],"sourceTerms":["coding"],"confidence":0.9,"reason":"..."}]}
        """
        var callCount = 0
        let job = makeJob(
            aiCall: { _ in
                callCount += 1
                if callCount == 1 { throw APIError.serverError("500") }
                return raw
            },
            ctx: ctx
        )
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready（重试后成功），实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(callCount, 2)  // 第一次失败，第二次成功
    }

    // MARK: - 输入不足

    func test_输入不足2条_状态idle不调AI() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)

        var aiCalled = false
        let job = makeJob(aiCall: { _ in aiCalled = true; return "{\"suggestions\":[]}" }, ctx: ctx)
        await job.run()

        XCTAssertEqual(job.state, .idle)
        XCTAssertFalse(aiCalled)  // 数据不足不应调 AI
    }

    // MARK: - markdown fence

    func test_markdownFence包裹_正确解析() async throws {
        let ctx = try makeContext()
        let id1 = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let raw = """
        ```json
        {"suggestions":[{"topicTitle":"编程实践","matchedTopicId":null,"thoughtIds":["\(id1.uuidString)"],"sourceTerms":["coding"],"confidence":0.85,"reason":"..."}]}
        ```
        """
        let job = makeJob(aiCall: { _ in raw }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
    }

    // MARK: - 已拒绝过滤

    func test_已拒绝的建议被过滤() async throws {
        let ctx = try makeContext()
        let id1 = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        // 预先拒绝「编程实践 + coding」建议
        let rejectionRepo = ConvergenceRejectionRepository(context: ctx)
        try rejectionRepo.reject(topicTitle: "编程实践", sourceTerms: ["coding"], expiresInDays: 30)

        let raw = """
        {"suggestions":[{"topicTitle":"编程实践","matchedTopicId":null,"thoughtIds":["\(id1.uuidString)"],"sourceTerms":["coding"],"confidence":0.9,"reason":"..."}]}
        """
        let job = makeJob(aiCall: { _ in raw }, ctx: ctx)
        await job.run()

        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望 ready，实际 \(job.state)")
        }
        XCTAssertTrue(suggestions.isEmpty)  // 唯一建议已被拒绝，过滤掉
    }

    // MARK: - Token protection

    func test_输入未变化时第二次归纳不重复调用AI并恢复建议() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)
        _ = try seedThought(tag: "coding", ctx: ctx)

        let suiteName = "ThoughtTagConvergenceJobTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ThoughtTagConvergenceJobStore(userDefaults: defaults)
        var callCount = 0
        let job = makeJob(
            aiCall: { _ in
                callCount += 1
                return "{\"suggestions\":[]}"
            },
            ctx: ctx,
            jobStore: store
        )

        await job.run()
        await job.run()

        XCTAssertEqual(callCount, 1)
        guard case .ready(let suggestions) = job.state else {
            return XCTFail("期望恢复 ready，实际 \(job.state)")
        }
        XCTAssertEqual(suggestions.count, 1)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_自动应用生成主题后再次归纳不重复调用AI() async throws {
        let ctx = try makeContext()
        let id1 = try seedThought(tag: "coding", ctx: ctx)
        let id2 = try seedThought(tag: "coding", ctx: ctx)
        let id3 = try seedThought(tag: "coding", ctx: ctx)

        let suiteName = "ThoughtTagConvergenceJobTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ThoughtTagConvergenceJobStore(userDefaults: defaults)
        let raw = """
        {"suggestions":[{"topicTitle":"编程实践","matchedTopicId":null,"thoughtIds":["\(id1.uuidString)","\(id2.uuidString)","\(id3.uuidString)"],"sourceTerms":["coding"],"confidence":0.9,"reason":"三条都在谈编程"}]}
        """
        var callCount = 0
        let job = makeJob(
            aiCall: { _ in
                callCount += 1
                return raw
            },
            ctx: ctx,
            jobStore: store
        )

        await job.run(autoApply: true)
        await job.run(autoApply: true)

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(job.state, .idle)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - reset

    func test_reset状态回idle() async throws {
        let ctx = try makeContext()
        _ = try seedThought(tag: "coding", ctx: ctx)

        let job = makeJob(aiCall: { _ in "{\"suggestions\":[]}" }, ctx: ctx)
        await job.run()
        XCTAssertEqual(job.state, .idle)  // 输入不足本就 idle

        job.reset()
        XCTAssertEqual(job.state, .idle)
    }
}
