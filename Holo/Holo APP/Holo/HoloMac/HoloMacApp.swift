//
//  HoloMacApp.swift
//  HoloMac
//
//  Holo Mac 版入口：Phase B 想法模块三栏浏览工作台为主界面；
//  Phase A 的只读验证页（MacSyncVerifyView）保留在菜单栏「视图 > 同步验证页」，
//  DEBUG 构建下可用。
//  Phase E：接入想法模块 AI 自动整理链路（与 iOS HoloApp 同一条启动序，见
//  organizationStartup——通知/Widget/MemoryInsight 等 iOS 专属项不带，对照表
//  见 Phase E 交付说明）。
//

import SwiftUI

@main
struct HoloMacApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // V3 Phase 1：存量想法-主题关系一次性回填 ThoughtTopicLink（幂等，后台执行）
        ThoughtTopicLinkBackfillBootstrap.performIfNeeded()

        // V3 Phase 2：本机语义索引冷启动装配（幂等；内部自行等 Core Data 就绪，
        // 挂 change feed 后保存想法自动入 embedding/relate 队列）
        Task.detached(priority: .utility) {
            await ThoughtSemanticPipeline.shared.bootstrap()
        }

        // 触发 Core Data 异步加载（容器由主线程先建立，与 iOS 启动序一致，
        // 防后台任务抢跑懒加载与 viewContext 主队列互锁）
        CoreDataStack.shared.prepareIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ime-diag") {
                // IME 自检自动模式：open HoloMac.app --args --ime-diag
                // （openWindow(id:) 在启动帧会被静默吞掉，自检窗口直接当主窗口开）
                MacEditorIMEDiagnosticView()
            } else {
                workspaceRoot
            }
            #else
            workspaceRoot
            #endif
        }
        .commands {
            CommandMenu(String(localized: "视图")) {
                #if DEBUG
                Button(String(localized: "同步验证页")) {
                    openWindow(id: "mac-sync-verify")
                }
                .accessibilityIdentifier("mac.menu.syncVerify")
                Button(String(localized: "编辑器 IME 自检")) {
                    openWindow(id: "mac-ime-diag")
                }
                .accessibilityIdentifier("mac.menu.imeDiag")
                Divider()
                #endif
                Button(String(localized: "搜索想法")) {
                    HoloShortcutBus.shared.post(.searchInCurrentModule)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        #if DEBUG
        WindowGroup("同步验证页", id: "mac-sync-verify") {
            MacSyncVerifyView()
                .frame(minWidth: 720, minHeight: 520)
        }

        /// IME 组字回归自检（2026-10-26 灾难级组字 bug 防回归）：
        /// `open HoloMac.app --args --ime-diag` 自动开跑，结果见窗口与 os_log（MacIMEDiag）
        WindowGroup("编辑器 IME 自检", id: "mac-ime-diag") {
            MacEditorIMEDiagnosticView()
        }
        #endif
    }

    /// 主工作台（含启动链与前台化续做；IME 自检模式下不挂载）
    private var workspaceRoot: some View {
        MacThoughtsWorkspaceView()
            .task {
                await organizationStartup()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // 与 iOS 回前台同链：pending 队列续做 + 语义对账续跑（均幂等）
                ThoughtOrganizationQueue.shared.appWillEnterForeground()
                Task {
                    await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
                    await ThoughtSemanticPipeline.shared.kickQueue()
                }
            }
    }

    // MARK: - AI 想法整理启动链

    /// 与 iOS HoloApp 启动链中「想法整理相关」调用同清单（HoloApp.swift .task 段）：
    /// V2 标签整理 backfill / 队列恢复 / 归并任务恢复。全部幂等。
    private func organizationStartup() async {
        await CoreDataStack.shared.waitUntilReady()

        // AI 想法整理：首次启动 backfill + 存量标签归一化
        let repository = ThoughtRepository()
        repository.backfillTagAssignmentsIfNeeded()
        repository.normalizeExistingTags()
        // V2（2026-09-05 方案 §8.2）：旧 ai 关系标 legacy、词条身份回填（幂等，一次性）
        repository.migrateLegacyThoughtIndexIfNeeded()

        // 断网挂起 / 网络恢复续做（飞行模式写笔记等场景）
        ThoughtOrganizationQueue.shared.startObservingNetwork()
        ThoughtOrganizationQueue.shared.rebuildFromDatabase(coldStart: true)
        // V2：仅恢复上次会话的持久任务展示，不再自动发起新一轮归并生成
        Task {
            await ThoughtTagConvergenceJob.shared.resumePersistedJobIfNeeded()
        }
    }
}
