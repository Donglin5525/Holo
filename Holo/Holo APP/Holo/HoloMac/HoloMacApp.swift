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

        // 注意：此处不再主线程同步 prepareIfNeeded——2026-10-27 实测，容器目录
        // 的沙盒访问被系统层挂起时，主线程同步打开会把整个启动冻结成「无窗口
        // 假死」。连接改为 MacAppRootView 后台执行（带超时与状态呈现）。
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ime-diag") {
                // IME 自检自动模式：open HoloMac.app --args --ime-diag
                // （openWindow(id:) 在启动帧会被静默吞掉，自检窗口直接当主窗口开）
                MacEditorIMEDiagnosticView()
            } else {
                MacAppRootView()
            }
            #else
            MacAppRootView()
            #endif
        }
        .commands {
            // 标准「设置…」菜单位（⌘,）：与工作台齿轮同入口（经快捷键总线广播）
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "设置…")) {
                    HoloShortcutBus.shared.post(.openSettings)
                }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityIdentifier("mac.menu.settings")
            }

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

            // 前往 ⌘1/⌘2：模块切换（2026-10-28 任务模块迁移）
            CommandMenu(String(localized: "前往")) {
                Button(String(localized: "想法")) {
                    HoloShortcutBus.shared.post(.switchToThoughts)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button(String(localized: "任务")) {
                    HoloShortcutBus.shared.post(.switchToTasks)
                }
                .keyboardShortcut("2", modifiers: .command)
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

    /// 主工作台容器：启动链与前台化续做已上移 MacAppRootView
    /// （2026-10-27 恢复链上移重构，库失败态由 Root 的恢复页接管）
    /// 2026-10-28 起由 MacModuleRootView 承载「想法 | 任务」模块切换
    static func makeWorkspaceRoot() -> some View {
        MacModuleRootView()
    }

    // MARK: - AI 想法整理启动链

    /// 与 iOS HoloApp 启动链中「想法整理相关」调用同清单（HoloApp.swift .task 段）：
    /// V2 标签整理 backfill / 队列恢复 / 归并任务恢复。全部幂等。
    static func runOrganizationStartup() async {
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
