//
//  CloudKitSchemaInitializer.swift
//  Holo
//
//  开发期显式 CloudKit schema 上报（诊断工具）
//
//  背景：NSPersistentCloudKitContainer 的隐式 schema 上报依赖同步引擎
//  首跑；当它未触发时（发版前置「真机推 Development」失灵的场景），
//  用 Apple 官方开发期 API initializeCloudKitSchema 强制比较本地模型与
//  开发库并上报差异，Xcode 控制台打印全过程。
//
//  线程红线：initializeCloudKitSchema 是同步阻塞调用（含网络）。本工程
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，未标注的 async 函数会被推断为
//  @MainActor——Task.detached 闭包一 await 就 hop 回主线程（2026-10-25 真机
//  watchdog 0x8BADF00D 三连崩实锤）。执行体必须 nonisolated + GCD 后台队列。
//
//  用法：仅 DEBUG 构建生效；加启动参数 -HoloCloudKitSchemaInit 显式触发
//  （Xcode scheme 的 Arguments Passed On Launch，或 devicectl launch 末尾追加）。
//  无自动触发、无幂等标记——要求跑就跑，跑没跑看 [SchemaInit] 日志。

import CoreData
import Foundation

enum CloudKitSchemaInitializer {
    /// 启动参数开关：发版前含新表时手动加，跑一次显式上报。
    nonisolated static let launchArgument = "-HoloCloudKitSchemaInit"

    /// store 就绪后由 App 启动流程调用；命中启动参数才执行，立即返回，
    /// 阻塞比对在 GCD 后台队列进行，不占主线程。
    nonisolated static func runIfNeeded(container: NSPersistentContainer) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        NSLog("[SchemaInit] 命中启动参数：GCD 后台队列跑显式 schema 初始化…")
        DispatchQueue.global(qos: .utility).async {
            Self.run(container: container)
        }
        #endif
    }

    #if DEBUG
    nonisolated private static func run(container: NSPersistentContainer) {
        guard let cloudKitContainer = container as? NSPersistentCloudKitContainer else {
            NSLog("[SchemaInit] 容器不是 NSPersistentCloudKitContainer（CloudKit 不可用分支）——先查同步诊断。")
            return
        }
        NSLog("[SchemaInit] 开始显式 schema 初始化（后台线程，对比本地模型与开发库）…")
        do {
            try cloudKitContainer.initializeCloudKitSchema(options: [.printSchema])
            NSLog("[SchemaInit] ✅ schema 初始化完成，差异已上报 Development。")
        } catch {
            NSLog("[SchemaInit] ❌ schema 初始化失败：\(error)")
        }
    }
    #endif
}
