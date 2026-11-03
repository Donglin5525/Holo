import CoreData
import Foundation

// 编译时启用与 App 相同的 -default-isolation MainActor，防止 detached 再次跳回主线程。
// 拦截 schema API，不装载 CloudKit store、不访问网络或用户偏好。
nonisolated final class SchemaTestDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    override func bool(forKey defaultName: String) -> Bool { lock.withLock { completed } }
    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { completed = value as? Bool ?? false }
    }
}

nonisolated final class SchemaTestContainer: NSPersistentCloudKitContainer, @unchecked Sendable {
    let lock = NSLock()
    private var callCount = 0
    let shouldFail: Bool
    let started = DispatchSemaphore(value: 0)

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
        super.init(name: "SchemaTest", managedObjectModel: NSManagedObjectModel())
    }

    override class func defaultDirectoryURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[2])
    }

    var calls: Int { lock.withLock { callCount } }

    override func initializeCloudKitSchema(options: NSPersistentCloudKitContainerSchemaInitializationOptions = []) throws {
        guard !Thread.isMainThread else {
            fputs("FAIL: schema API 回到了主线程\n", stderr)
            exit(1)
        }
        lock.withLock { callCount += 1 }
        started.signal()
        // 模拟同步网络操作；期间主线程的心跳必须继续执行。
        Thread.sleep(forTimeInterval: 0.4)
        if shouldFail { throw NSError(domain: "SchemaTest", code: 7) }
    }
}

@main
struct CloudKitSchemaStartupStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        let mode = CommandLine.arguments[1]
        let defaults = SchemaTestDefaults(suiteName: "holo.schema.tests.\(UUID())")!
        let container = SchemaTestContainer(shouldFail: mode == "failure")
        var heartbeatCount = 0

        if mode == "normal" {
            // 即使旧版本失败过、完成标记为 false，普通启动也不执行管理操作。
            for _ in 0..<3 {
                CloudKitSchemaInitializer.runIfRequested(container: container, environment: [:], defaults: defaults)
            }
        } else {
            CloudKitSchemaInitializer.runIfRequested(
                container: container,
                environment: ["HOLO_INITIALIZE_CLOUDKIT_SCHEMA": "1"],
                defaults: defaults
            )
            expect(container.started.wait(timeout: .now() + 2) == .success, "显式请求必须确实执行后台 API")
            if mode == "duplicate" {
                CloudKitSchemaInitializer.runIfRequested(
                    container: container,
                    environment: ["HOLO_INITIALIZE_CLOUDKIT_SCHEMA": "1"],
                    defaults: defaults
                )
            }
        }
        for index in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                heartbeatCount += 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            expect(heartbeatCount == 3, "同步 schema 操作期间主线程必须继续响应")
            expect(container.calls == (mode == "normal" ? 0 : 1), "日常启动零调用，显式请求只执行一次")
            expect(defaults.bool(forKey: CloudKitSchemaInitializer.doneKey) == (mode != "normal" && mode != "failure"),
                   "只有真实成功才落完成标记")
            if mode == "failure" {
                // 失败后日常启动仍不能重试，避免「杀 App 重开又卡住」。
                CloudKitSchemaInitializer.runIfRequested(container: container, environment: [:], defaults: defaults)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    expect(container.calls == 1, "失败后普通启动不能自动重试")
                    print("PASS schema failure: 后台失败后日常启动不重试，主线程保持响应")
                    exit(0)
                }
            } else {
                print("PASS schema \(mode): 主线程持续响应，后台调用次数与完成标记正确")
                exit(0)
            }
        }
        RunLoop.main.run()
    }
}
