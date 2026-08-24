//
//  HoloApp.swift
//  Holo
//
//  应用入口 - Holo AI 个人助理
//

import SwiftUI
import BackgroundTasks
import UniformTypeIdentifiers

/// Holo 应用入口
/// 一款"个人数据资产 + AI 规划"一体化的个人 AI 助理
@main
struct HoloApp: App {

    // MARK: - Observed Objects

    /// 深色模式管理器
    @StateObject private var darkModeManager = DarkModeManager.shared
    @StateObject private var plusActionCoordinator = HoloPlusActionCoordinator.shared

    /// 应用锁：isLocked 在冷启动首帧前同步确定，根部闸门层防内容闪现（方案 §5.3）
    @ObservedObject private var appLock = AppLockManager.shared

    /// 外部文件导入状态（拖拽 CSV 到模拟器 / "Open In" 打开）
    @State private var pendingImportURL: CSVFileURL?

    /// 场景阶段：前后台切换驱动 Agent 后台续跑（Agent Runtime 为产品默认能力）
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        // hosted test 宿主：不启动任何业务服务，app 只需提供活着的主线程与 bundle。
        // 正常启动的后台服务/通知监听会与测试 task 并发交互，触发运行时 double-free 崩溃。
        guard !TestHostEnvironment.isHostedByXCTest else { return }

        // 同步设置通知代理，确保冷启动时 didReceive 不被错过
        TodoNotificationService.shared.setupDelegate()
        TodoNotificationService.shared.registerNotificationCategories()

        // 注册后台洞察生成任务
        MemoryInsightBackgroundService.shared.registerBackgroundTask()

        // 注册周期性支出自动补账任务
        SpendingProjectBackgroundService.shared.registerBackgroundTask()

        // 长期记忆只保留严格语义 V2；先清理旧格式，再允许新洞察写入候选。
        HoloLongTermMemoryStore.performSemanticV2MigrationIfNeeded()

        // 迁移旧格式学习映射 key（type|candidate → type|primary|candidate）
        CategoryLearnedMapping.migrateOldFormatKeys()

        // 触发 Core Data 异步加载（不阻塞主线程，避免首次创建 SQLite 时死锁）
        // store 加载在后台进行，UI 先以默认值渲染，加载完成后通过 await 切换
        CoreDataStack.shared.prepareIfNeeded()

        // 签名未携带 iCloud entitlement 时，CloudKit 容器初始化会触发系统 trap。
        // 因此只在运行时确认可用后提前启动监听；设置页仍可按需展示不可用状态。
        if CloudKitRuntimeAvailability.isAvailable {
            _ = ICloudSyncStatusService.shared
        }

        // 监听财务/想法/习惯/待办/目标/纪念日变更，维护桌面小组件使用的轻量快照
        HoloWidgetSnapshotService.shared.startObserving()

        // 监听周期回放生成，异步维护远期累计摘要（失败不影响主流程）
        HoloReplayDigestObserver.startObserving()
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            if TestHostEnvironment.isHostedByXCTest {
                // 测试宿主不渲染业务 UI：HomeView 等界面的 .task 会启动
                // HomeScheduleService/各 ViewModel 刷新，同样会与测试并发交互导致崩溃。
                Color.clear.ignoresSafeArea()
            } else {
                // 应用锁闸门层与业务根视图同帧渲染：锁定时首帧即锁屏，无内容闪现；
                // 热回时由 AppLockManager 的系统级窗口盖住浮层（fullScreenCover/sheet）
                ZStack {
                    appRoot

                    if appLock.isLocked || appLock.isShowingPrivacyShield {
                        AppLockOverlayView()
                            .zIndex(10)
                            // 出现必须瞬时就位（不透明遮蔽），消失可淡出
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                }
                .animation(HoloAnimation.standard, value: appLock.isLocked)
            }
        }
    }

    /// 业务根视图与启动链；hosted test 下不挂载（见 init 注释）。
    private var appRoot: some View {
        ContentView()
            .preferredColorScheme(darkModeManager.colorScheme)
            .onOpenURL { url in
                guard url.isFileURL else {
                    DeepLinkState.shared.handle(url: url)
                    return
                }
                let ext = url.pathExtension.lowercased()
                let supported: Set<String> = ["csv", "txt", "tsv", "xlsx", "zip"]
                guard supported.contains(ext) else { return }
                pendingImportURL = CSVFileURL(url: url)
            }
            .fullScreenCover(item: $pendingImportURL) { wrapper in
                CSVQuickImportView(fileURL: wrapper.url) {
                    pendingImportURL = nil
                }
            }
            .fullScreenCover(isPresented: $plusActionCoordinator.isPaywallPresented) {
                HoloPlusPaywallView(context: plusActionCoordinator.context)
            }
            .task {
                await SensitiveDebugDataMigration.runIfNeeded()
                await HoloSubscriptionService.shared.refreshStatus()

                // 检查通知权限状态
                TodoNotificationService.shared.checkAuthorizationStatus()

                // Store 就绪后安排下一次周期性支出补账；具体执行仍由系统后台策略决定
                await CoreDataStack.shared.waitUntilReady()
                // 先恢复用户主动发起的周期回放，再执行低优先级自动洞察与历史回填。
                await HoloPeriodReplayCoordinator.shared.appDidLaunch()

                // 目标风险通知：按当前数据全量重排（文案在排程时固定，iOS 更新后可能清通知）
                GoalNotificationService.shared.rescheduleAll()

                // 每日早报：滚动重排未来 7 天（含旧「每日提醒」一次性迁移）
                await DailyBriefScheduler.shared.handleAppActivity()
                // 习惯打卡提醒 + 周一晨报：滚动重排
                await HabitReminderScheduler.shared.handleAppActivity()
                await WeeklyBriefScheduler.shared.handleAppActivity()
                // 财务提醒：周期账单到期（Plus）+ 预算超支检查
                await BillDueReminderScheduler.shared.handleAppActivity()
                await BudgetOverrunNotificationService.shared.handleAppActivity()

                #if DEBUG
                let appStoreScreenshotModeActive =
                    await HoloAppStoreScreenshotSeeder.runIfRequested()
                let simulatorMemoryValidationActive =
                    await HoloMemorySimulatorValidationScenario.runIfRequested()
                #else
                let appStoreScreenshotModeActive = false
                let simulatorMemoryValidationActive = false
                #endif

                if !simulatorMemoryValidationActive {
                    await HoloMemoryRuntime.shared.migrateLegacyMemoryIfNeeded()
                    await HoloMemoryRuntime.shared.reconcilePendingCandidatesIfNeeded()
                }
                await HoloMemorySettings.shared.reconcileWithRepository()
                if !simulatorMemoryValidationActive {
                    await HoloMemoryObservationScheduler.shared.lightweightCheck(trigger: .appLaunch)
                }

                // 统一领域记忆链是唯一写入口；旧 JSON 仅保留一个版本用于迁移回滚。
                FinanceRepository.shared.setup()
                SpendingProjectBackgroundService.shared.scheduleNextTask()
                if !appStoreScreenshotModeActive {
                    MemoryInsightBackgroundService.shared.scheduleBackgroundTask()
                    await MemoryInsightBackgroundService.shared.checkForegroundCompensation()
                }

                // 启动时轻量聚合未消费反馈（更新 rerank 用的偏好）
                if InsightFeatureFlags.preferenceLearningEnabled {
                    let context = CoreDataStack.shared.viewContext
                    InsightFeedbackAggregator.shared.aggregate(in: context)
                }

                // AI 想法整理：首次启动 backfill + 恢复 pending 队列
                let repository = ThoughtRepository()
                repository.backfillTagAssignmentsIfNeeded()
                repository.normalizeExistingTags()

                ThoughtOrganizationQueue.shared.rebuildFromDatabase()
                Task {
                    await ThoughtTagConvergenceJob.shared.resumePersistedJobIfNeeded()
                }

                // 回收站启动维护：旧软删标记一次性迁移 + 30 天过期数据物理清理
                Task {
                    await RecycleBinService.shared.performStartupMaintenance()
                }

                // 首屏数据准备后刷新一次小组件快照，保证冷启动后桌面数据可用
                await HoloWidgetSnapshotService.shared.refreshAllSnapshots()

                // 老用户首次升级：回填周期回放远期累计摘要（后台执行，不阻塞 UI）
                Task {
                    await HoloReplayDigestService.shared.backfillIfNeeded(
                        historyRepo: MemoryInsightRepository()
                    )
                }

                if HoloAIFeatureFlags.agentRuntimeEnabled {
                    await MainActor.run {
                        HoloBackgroundContinuationManager.shared.appDidLaunch()
                        // 网络恢复自动唤醒等待网络的 Agent 任务（锁屏高可用）
                        HoloBackgroundContinuationManager.shared.startNetworkRecoveryMonitoring()
                    }
                }
            }
            // §7.2：设备解锁（protected data 可用）后由 Scheduler 恢复等待解锁的 Agent 任务
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                if HoloAIFeatureFlags.agentRuntimeEnabled {
                    HoloBackgroundContinuationManager.shared.protectedDataDidBecomeAvailable()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                #if DEBUG
                guard HoloMemorySimulatorValidationEnvironment.current == nil else { return }
                guard !HoloAppStoreScreenshotSeeder.isRequested else { return }
                #endif
                switch phase {
                case .background:
                    Task {
                        await HoloMemoryObservationScheduler.shared.lightweightCheck(
                            trigger: .enteredBackground
                        )
                    }
                    if HoloAIFeatureFlags.agentRuntimeEnabled {
                        HoloBackgroundContinuationManager.shared.appDidEnterBackground()
                    }
                case .active:
                    HoloPeriodReplayCoordinator.shared.appWillEnterForeground()
                    Task {
                        // 回前台滚动重排早报/习惯提醒/晨报：跨天驻留后文案快照已过期
                        await DailyBriefScheduler.shared.handleAppActivity()
                        await HabitReminderScheduler.shared.handleAppActivity()
                        await WeeklyBriefScheduler.shared.handleAppActivity()
                        // 财务提醒：周期账单到期（Plus）+ 预算超支检查
                        await BillDueReminderScheduler.shared.handleAppActivity()
                        await BudgetOverrunNotificationService.shared.handleAppActivity()
                        await MemoryInsightBackgroundService.shared.checkForegroundCompensation()
                        await HoloReplayDigestService.shared.backfillIfNeeded(
                            historyRepo: MemoryInsightRepository()
                        )
                        await HoloMemoryObservationScheduler.shared.lightweightCheck(
                            trigger: .becameActive
                        )
                    }
                    if HoloAIFeatureFlags.agentRuntimeEnabled {
                        HoloBackgroundContinuationManager.shared.appWillEnterForeground()
                    }
                default:
                    break
                }
            }
    }
}

// MARK: - CSV 文件 URL 包装

/// Identifiable URL 包装，用于 .fullScreenCover(item:)
struct CSVFileURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - CSV 快速导入视图

/// 从外部打开 CSV 文件时的导入处理视图
struct CSVQuickImportView: View {
    @Environment(\.dismiss) var dismiss

    let fileURL: URL
    let onDismiss: () -> Void

    @State private var importResult: BatchImportResult?
    @State private var showImportResult = false
    @State private var undoErrorMessage: String?
    @State private var showUndoError = false

    /// 复制到临时目录的安全副本（避免安全域引用失效）
    @State private var safeFileURL: URL?

    var body: some View {
        Group {
            if let url = safeFileURL {
                ImportPreviewSheet(fileURL: url) { result in
                    importResult = result
                    safeFileURL = nil        // 关闭 ImportPreviewSheet
                    showImportResult = true
                }
            } else if !showImportResult {
                ProgressView("正在准备文件...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.holoBackground)
            }
        }
        .onAppear {
            prepareFile()
        }
        .sheet(isPresented: $showImportResult, onDismiss: {
            // 结果弹窗关闭后：刷新财务数据 + 关闭整个快速导入界面
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            onDismiss()
        }) {
            if let result = importResult {
                ImportResultSheet(result: result, onUndo: {
                    guard let batchId = result.batchId else { return }
                    Task {
                        do {
                            _ = try await FinanceRepository.shared.undoImportBatch(batchId: batchId)
                            // 撤回完成后再刷一次（sheet onDismiss 的刷新发生在撤回开始时，数据可能尚未删完）
                            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                        } catch {
                            undoErrorMessage = error.localizedDescription
                            showUndoError = true
                        }
                    }
                })
            }
        }
        .alert("撤回失败", isPresented: $showUndoError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(undoErrorMessage ?? "请稍后在 设置 → 数据导入导出 中重试")
        }
    }

    private func prepareFile() {
        // 把外部文件复制到临时目录（保留原扩展名），避免安全域引用在 sheet 生命周期内失效
        let ext = fileURL.pathExtension.lowercased()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo_quick_import_\(UUID().uuidString).\(ext.isEmpty ? "csv" : ext)")
        if fileURL.startAccessingSecurityScopedResource() {
            defer { fileURL.stopAccessingSecurityScopedResource() }
            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                // 账单预处理：zip 解压 / xlsx 转 CSV（与导入导出页同一条链）
                switch ext {
                case "zip":
                    safeFileURL = try BillArchiveExtractor.extract(archiveURL: tempURL)
                case "xlsx":
                    safeFileURL = try BillExcelReader.convertToCSV(url: tempURL)
                default:
                    safeFileURL = tempURL
                }
            } catch {
                // 复制/预处理失败，直接用原 URL 尝试
                safeFileURL = fileURL
            }
        } else {
            safeFileURL = fileURL
        }
    }
}
