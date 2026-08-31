//
//  ThoughtOrganizationQueueTests.swift
//  HoloTests
//
//  想法整理队列断网挂起/恢复续做测试
//  覆盖 连接类错误重试耗尽回退 pending / 其他错误仍标 failed /
//       断网挂起不发起请求 / 网络恢复沿续做 / 在途请求遇断网立即回退不空转重试
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class ThoughtOrganizationQueueTests: XCTestCase {

    // MARK: - Scaffold

    private var savedAutoOrganizationSetting: Any?

    override func setUp() async throws {
        // 队列恢复路径（rebuildFromDatabase）尊重自动分类开关；
        // 测试宿主的 UserDefaults 状态不可控，显式开启并在 tearDown 还原
        savedAutoOrganizationSetting = UserDefaults.standard.object(
            forKey: ThoughtAIClassificationPolicy.isEnabledKey
        )
        UserDefaults.standard.set(true, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
    }

    override func tearDown() async throws {
        if let saved = savedAutoOrganizationSetting as? Bool {
            UserDefaults.standard.set(saved, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        }
    }

    private func makeContext() throws -> NSManagedObjectContext {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "OrgQueueTest", managedObjectModel: model)
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        var err: Error?
        container.loadPersistentStores { _, e in err = e }
        if let err { throw err }
        CoreDataTestSupport.retain(container, container.viewContext)
        return container.viewContext
    }

    /// organize 桩：记录调用次数，可注入错误；成功时模拟 service 写 organized
    private final class OrganizeStub {
        var callCount = 0
        var error: Error?
        /// 抛错前置钩子：模拟「请求飞行途中网络断了」（错误返回前 NWPathMonitor 先回调）
        var onBeforeFailure: (() -> Void)?
        private let onSuccess: (UUID) throws -> Void

        init(onSuccess: @escaping (UUID) throws -> Void) {
            self.onSuccess = onSuccess
        }

        func call(_ id: UUID) async throws {
            callCount += 1
            if let error {
                onBeforeFailure?()
                throw error
            }
            try onSuccess(id)
        }
    }

    private func makeQueue(
        context: NSManagedObjectContext,
        organize: @escaping @MainActor (UUID) async throws -> Void
    ) -> ThoughtOrganizationQueue {
        let repository = ThoughtRepository(context: context)
        CoreDataTestSupport.retain(repository)
        let queue = ThoughtOrganizationQueue(
            service: ThoughtOrganizationService(),
            repository: repository,
            retryIntervals: [0.01, 0.01, 0.01],
            maxRetryCount: 3,
            itemInterval: 0.01,
            organize: organize
        )
        CoreDataTestSupport.retain(queue)
        return queue
    }

    @discardableResult
    private func seedThought(
        in context: NSManagedObjectContext,
        organizedStatus: String = "pending"
    ) throws -> UUID {
        let thought = context.insertTestObject(Thought.self)
        let id = UUID()
        thought.id = id
        thought.content = "飞行模式写的笔记，长度足够触发整理流程"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = organizedStatus
        thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId
        try context.save()
        return id
    }

    private func status(of id: UUID, in context: NSManagedObjectContext) throws -> String {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first?.organizedStatus ?? "<missing>"
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时：\(message)")
    }

    // MARK: - 连接类错误重试耗尽：回退 pending（等网络恢复续做），不进 failed 终态

    func testConnectivityLossExhaustedRollsBackToPending() async throws {
        let context = try makeContext()
        let stub = OrganizeStub { id in
            try ThoughtRepository(context: context).updateOrganizedStatus(
                thoughtId: id, status: "organized"
            )
        }
        stub.error = APIError.networkUnavailable
        let queue = makeQueue(context: context) { try await stub.call($0) }
        let id = try seedThought(in: context)

        queue.enqueueManual(thoughtId: id)

        await waitUntil("连接类错误应重试 1+3 次后停止") { stub.callCount >= 4 }
        await waitUntil("重试耗尽后应回退 pending") {
            (try? status(of: id, in: context)) == "pending"
        }
        XCTAssertEqual(stub.callCount, 4, "1 次首调 + 3 次重试")
    }

    // MARK: - 非连接类错误重试耗尽：维持现状标 failed

    func testOtherErrorExhaustedStillMarksFailed() async throws {
        let context = try makeContext()
        let stub = OrganizeStub { _ in }
        stub.error = APIError.serverError("AI 返回结构异常")
        let queue = makeQueue(context: context) { try await stub.call($0) }
        let id = try seedThought(in: context)

        queue.enqueueManual(thoughtId: id)

        await waitUntil("服务端错误应重试 1+3 次后停止") { stub.callCount >= 4 }
        await waitUntil("重试耗尽后应标 failed") {
            (try? status(of: id, in: context)) == "failed"
        }
    }

    // MARK: - 断网挂起：不发起注定失败的请求，条目留在队列等恢复沿

    func testOfflinePauseDefersOrganizeUntilRestore() async throws {
        let context = try makeContext()
        let stub = OrganizeStub { id in
            try ThoughtRepository(context: context).updateOrganizedStatus(
                thoughtId: id, status: "organized"
            )
        }
        let queue = makeQueue(context: context) { try await stub.call($0) }
        let id = try seedThought(in: context)

        queue.handleNetworkPathChange(satisfied: false)
        queue.enqueueManual(thoughtId: id)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(stub.callCount, 0, "断网挂起时不应发起整理请求")
        XCTAssertFalse(queue.isEmpty, "条目应留在队列，等网络恢复沿续做")

        queue.handleNetworkPathChange(satisfied: true)
        await waitUntil("网络恢复后应续做整理") { stub.callCount == 1 }
        await waitUntil("恢复续做应完成整理") {
            (try? status(of: id, in: context)) == "organized"
        }
    }

    // MARK: - 在途请求遇断网：立即回退 pending，不再空转重试

    func testInFlightFailureWhileOfflineSkipsRetries() async throws {
        let context = try makeContext()
        var queueRef: ThoughtOrganizationQueue?
        let stub = OrganizeStub { _ in }
        stub.error = APIError.networkUnavailable
        stub.onBeforeFailure = {
            // 模拟请求飞行途中断网（NWPathMonitor 回调先于错误返回）
            queueRef?.handleNetworkPathChange(satisfied: false)
        }
        let queue = makeQueue(context: context) { try await stub.call($0) }
        queueRef = queue
        let id = try seedThought(in: context)

        queue.enqueueManual(thoughtId: id)

        await waitUntil("首轮失败应立即回退") { stub.callCount >= 1 }
        await waitUntil("断网失败应直接回退 pending") {
            (try? status(of: id, in: context)) == "pending"
        }
        // 留出远超重试间隔（0.01s）的窗口，确认没有重试被排上
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stub.callCount, 1, "断网确认后不应再排重试")
    }
}
