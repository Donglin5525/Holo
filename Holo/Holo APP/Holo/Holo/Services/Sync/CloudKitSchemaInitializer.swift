//
//  CloudKitSchemaInitializer.swift
//  Holo
//
//  开发期显式 CloudKit schema 上报（一次性诊断工具）
//
//  背景：NSPersistentCloudKitContainer 的隐式 schema 上报依赖同步引擎
//  首跑；当它未触发时（发版前置「真机推 Development」失灵的场景），
//  用 Apple 官方开发期 API initializeCloudKitSchema 强制比较本地模型与
//  开发库并上报差异，Xcode 控制台打印全过程。
//
//  注意：initializeCloudKitSchema 是同步阻塞调用（含网络），必须在
//  后台线程执行，禁止挂主线程（2026-10-25 实测主线程挂起）。
//
//  用法：仅 DEBUG 构建且 Xcode 启动环境显式设置
//  HOLO_INITIALIZE_CLOUDKIT_SCHEMA=1 时执行。日常开发包不自动上报，
//  避免弱网或失败重试把每次启动都变成管理操作。
//

import CoreData
import Foundation

// 工程默认 MainActor；必须显式 nonisolated，否则 Task.detached 内 await run()
// 仍会跳回主线程执行同步网络调用（2026-10-27 真机 watchdog 堆栈实证）。
nonisolated enum CloudKitSchemaInitializer {
    /// 本机构建跑成过一次的标记（失败/被杀不写，下次显式请求时重试）。
    static let doneKey = "holo_cloudkit_schema_initialized_v2"
    private static let queue = DispatchQueue(label: "com.holo.cloudkit.schema-initializer", qos: .utility)

    /// store 就绪后仅接收显式开发请求；日常启动不触碰 schema 和网络。
    static func runIfRequested(
        container: NSPersistentContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        #if DEBUG
        guard environment["HOLO_INITIALIZE_CLOUDKIT_SCHEMA"] == "1" else { return }
        NSLog("[SchemaInit] 计划执行：切后台线程跑显式 schema 初始化…")
        queue.async(execute: DispatchWorkItem {
            Self.run(container: container, defaults: defaults)
        })
        #endif
    }

    #if DEBUG
    private static func run(container: NSPersistentContainer, defaults: UserDefaults) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // 串行队列内检查完成标记，重复请求不会并发执行同一管理操作。
        guard defaults.bool(forKey: doneKey) == false else { return }

        guard let cloudKitContainer = container as? NSPersistentCloudKitContainer else {
            NSLog("[SchemaInit] 容器不是 NSPersistentCloudKitContainer（CloudKit 不可用分支）——先查同步诊断。")
            defaults.set(true, forKey: doneKey)
            return
        }
        NSLog("[SchemaInit] 开始显式 schema 初始化（后台线程，对比本地模型与开发库）…")
        do {
            try cloudKitContainer.initializeCloudKitSchema(options: [.printSchema])
            defaults.set(true, forKey: doneKey)
            NSLog("[SchemaInit] ✅ schema 初始化完成，差异已上报 Development。")
        } catch {
            // 失败不留标记；只在下一次显式开发请求时重试。
            NSLog("[SchemaInit] ❌ schema 初始化失败（不会在日常启动自动重试）：\(error)")
        }
    }
    #endif
}
