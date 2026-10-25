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
//  用法：仅 DEBUG 构建生效。每台设备首次启动自动执行一次；
//  成功后写完成标记，失败或被杀（未完成）下次启动自动重试。
//

import CoreData
import Foundation

enum CloudKitSchemaInitializer {
    /// 本机构建跑成过一次的标记（失败/被杀不写，下次启动重试）。
    static let doneKey = "holo_cloudkit_schema_initialized_v2"

    /// store 就绪后由 App 启动流程调用；内部切后台线程，立即返回。
    static func runIfNeeded(container: NSPersistentContainer) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: doneKey) == false else { return }
        NSLog("[SchemaInit] 计划执行：切后台线程跑显式 schema 初始化…")
        Task.detached(priority: .utility) {
            await Self.run(container: container)
        }
        #endif
    }

    #if DEBUG
    private static func run(container: NSPersistentContainer) async {
        // 双检防并发重入（启动竞态下可能调度两次）。
        guard UserDefaults.standard.bool(forKey: doneKey) == false else { return }

        guard let cloudKitContainer = container as? NSPersistentCloudKitContainer else {
            NSLog("[SchemaInit] 容器不是 NSPersistentCloudKitContainer（CloudKit 不可用分支）——先查同步诊断。")
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        NSLog("[SchemaInit] 开始显式 schema 初始化（后台线程，对比本地模型与开发库）…")
        do {
            try cloudKitContainer.initializeCloudKitSchema(options: [.printSchema])
            UserDefaults.standard.set(true, forKey: doneKey)
            NSLog("[SchemaInit] ✅ schema 初始化完成，差异已上报 Development。")
        } catch {
            // 失败不留标记：下次启动自动重试。
            NSLog("[SchemaInit] ❌ schema 初始化失败：\(error)")
        }
    }
    #endif
}
