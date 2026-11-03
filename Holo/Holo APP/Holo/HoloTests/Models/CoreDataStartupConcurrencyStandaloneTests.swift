import CoreData
import Foundation
import os.log

// 由 run-startup-concurrency-tests.py 编译，不加入 hosted test，避免启动真实业务服务。
// 锁与加载状态机使用 CoreDataStack 原文；本文件只注入临时模型和可控的加载时机。
final class StartupTestContainer: NSPersistentContainer, @unchecked Sendable {
    override class func defaultDirectoryURL() -> URL { StartupTestEnvironment.directory }
}

nonisolated enum StartupTestEnvironment {
    static let mode = CommandLine.arguments[1]
    static let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    static let callbackStarted = DispatchSemaphore(value: 0)
    static let counters = NSLock()
    nonisolated(unsafe) static var resumedWaiters = 0
    nonisolated(unsafe) static var heartbeatCount = 0
}

nonisolated enum CloudKitRuntimeAvailability {
    static let isAvailable = false
    static let containerIdentifier = "unused.test.only"
}

extension CoreDataStack {
    static let recoveryLogger = Logger(subsystem: "com.holo.tests", category: "StartupConcurrency")

    func createDataModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "StartupNote"
        entity.managedObjectClassName = "NSManagedObject"
        let text = NSAttributeDescription()
        text.name = "text"
        text.attributeType = .stringAttributeType
        text.isOptional = true
        entity.properties = [text]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    static func resolveStoreURLForMigration(model: NSManagedObjectModel) -> URL {
        StartupTestEnvironment.directory.appendingPathComponent("\(StartupTestEnvironment.mode).sqlite")
    }

    static func loadStoreAllowingRecovery(
        _ container: NSPersistentContainer,
        logger: Logger,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        let load: @Sendable () -> Void = {
            if StartupTestEnvironment.mode == "failure" {
                StartupTestEnvironment.callbackStarted.signal()
                onFinish(NSError(domain: "HoloStartupTest", code: 42))
                return
            }
            container.loadPersistentStores { _, error in
                StartupTestEnvironment.callbackStarted.signal()
                onFinish(error)
            }
        }
        if StartupTestEnvironment.mode == "delayed" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8, execute: load)
        } else {
            load()
        }
    }
}

@main
struct CoreDataStartupConcurrencyStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let mode = StartupTestEnvironment.mode
        let stack = CoreDataStack.shared
        if mode == "main" {
            stack.prepareIfNeeded()
        } else {
            DispatchQueue.global().async { stack.prepareIfNeeded() }
        }
        if mode == "background" || mode == "failure" {
            expect(StartupTestEnvironment.callbackStarted.wait(timeout: .now() + 3) == .success,
                   "必须确实进入后台加载回调，不能用空跑冒充并发覆盖")
            // 模拟首帧布局期间主线程正在工作，后台回调同时试图配置主上下文。
            Thread.sleep(forTimeInterval: 0.05)
            print("QUERY_READINESS")
            fflush(stdout)
            let start = Date()
            expect(!stack.isReady, "主线程尚未完成上下文配置时不能提前报告就绪")
            expect(Date().timeIntervalSince(start) < 0.1, "读取就绪状态不能等待 Core Data 或主队列")
        }

        if mode == "delayed" {
            for index in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                    expect(!stack.isReady, "延迟加载期间应保持未就绪")
                    StartupTestEnvironment.counters.withLock { StartupTestEnvironment.heartbeatCount += 1 }
                }
            }
        }

        // 同时挂起 16 个等待者；每个再等一次覆盖「已到终态后立即返回」的路径。
        for _ in 0..<16 {
            Task.detached {
                await stack.waitUntilReady()
                await stack.waitUntilReady()
                let completed = StartupTestEnvironment.counters.withLock {
                    StartupTestEnvironment.resumedWaiters += 2
                    return StartupTestEnvironment.resumedWaiters == 32
                }
                if completed {
                    DispatchQueue.main.async { verifySettledState(stack, mode: mode) }
                }
            }
        }
        RunLoop.main.run()
    }

    static func verifySettledState(_ stack: CoreDataStack, mode: String) {
        expect(Thread.isMainThread, "在真实主线程核对主上下文配置")
        if mode == "failure" {
            expect(!stack.isReady, "失败不能冒充就绪")
            expect((stack.storeLoadError() as NSError?)?.code == 42, "等待者恢复后保留原始失败原因")
        } else {
            expect(stack.isReady, "所有等待者恢复前必须已就绪")
            expect(stack.storeLoadError() == nil, "成功状态不能残留失败")
            let context = stack.viewContext
            expect(context.automaticallyMergesChangesFromParent, "就绪时已启用云端合并")
            expect((context.mergePolicy as? NSMergePolicy)?.mergeType == .mergeByPropertyObjectTrumpMergePolicyType,
                   "就绪时已配置既有冲突合并策略")
            if mode == "delayed" {
                expect(StartupTestEnvironment.heartbeatCount == 5, "慢加载期间主线程五次心跳必须全部执行")
            }
            // 使用实际 SQLite 读写验证容器可用；不接 CloudKit，不触碰 AppGroup。
            do {
                let row = NSEntityDescription.insertNewObject(forEntityName: "StartupNote", into: context)
                row.setValue("并发启动后可正常保存", forKey: "text")
                try context.save()
                let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "StartupNote"))
                expect(count == 1,
                       "启动后保存和查询应正常工作")
            } catch {
                expect(false, "临时库实际读写失败：\(error)")
            }
        }
        print("PASS \(mode): 32 次等待恢复、状态与真实 Core Data 配置核对通过")
        exit(0)
    }
}
