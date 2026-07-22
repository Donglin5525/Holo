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

    /// Hosted XCTest 会启动 App 进程，但不应执行真实冷启动迁移、CloudKit 与后台任务。
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Observed Objects

    /// 深色模式管理器
    @StateObject private var darkModeManager = DarkModeManager.shared

    /// 外部文件导入状态（拖拽 CSV 到模拟器 / "Open In" 打开）
    @State private var pendingImportURL: CSVFileURL?

    /// 场景阶段：前后台切换驱动 Agent 后台续跑（Agent Runtime 为产品默认能力）
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        guard !Self.isRunningUnitTests else { return }

        HoloStartupCoordinator.shared.runCriticalOnce {
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

            // 监听财务/想法变更，维护桌面小组件使用的轻量快照
            HoloWidgetSnapshotService.shared.startObserving()
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                EmptyView()
            } else {
                ContentView()
                .preferredColorScheme(darkModeManager.colorScheme)
                .onOpenURL { url in
                    guard url.isFileURL else {
                        DeepLinkState.shared.handle(url: url)
                        return
                    }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "csv" || ext == "txt" || ext == "tsv" else { return }
                    pendingImportURL = CSVFileURL(url: url)
                }
                .fullScreenCover(item: $pendingImportURL) { wrapper in
                    CSVQuickImportView(fileURL: wrapper.url) {
                        pendingImportURL = nil
                    }
                }
                .task {
                    await HoloStartupCoordinator.shared.runOnce(.afterFirstFrame) {
                        await Self.runAfterFirstFrameStartup()
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
                        Task {
                            await MemoryInsightBackgroundService.shared.checkForegroundCompensation()
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
    }
}

private extension HoloApp {
    @MainActor
    static func runAfterFirstFrameStartup() async {
        await SensitiveDebugDataMigration.runIfNeeded()
        TodoNotificationService.shared.checkAuthorizationStatus()
        await CoreDataStack.shared.waitUntilReady()

        #if DEBUG
        let appStoreScreenshotModeActive = await HoloAppStoreScreenshotSeeder.runIfRequested()
        let simulatorMemoryValidationActive =
            await HoloMemorySimulatorValidationScenario.runIfRequested()
        #else
        let appStoreScreenshotModeActive = false
        let simulatorMemoryValidationActive = false
        #endif

        // 回填、调和、洞察和快照不阻塞首屏任务完成；进程内只调度一次。
        Task {
            await HoloStartupCoordinator.shared.runOnce(.backgroundBestEffort) {
                await runBackgroundBestEffortStartup(
                    appStoreScreenshotModeActive: appStoreScreenshotModeActive,
                    simulatorMemoryValidationActive: simulatorMemoryValidationActive
                )
            }
        }
    }

    @MainActor
    static func runBackgroundBestEffortStartup(
        appStoreScreenshotModeActive: Bool,
        simulatorMemoryValidationActive: Bool
    ) async {
        if !simulatorMemoryValidationActive {
            await HoloMemoryRuntime.shared.migrateLegacyMemoryIfNeeded()
            await HoloMemoryRuntime.shared.reconcilePendingCandidatesIfNeeded()
        }
        await HoloMemorySettings.shared.reconcileWithRepository()
        if !simulatorMemoryValidationActive {
            await HoloMemoryObservationScheduler.shared.lightweightCheck(trigger: .appLaunch)
        }

        FinanceRepository.shared.setup()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        if !appStoreScreenshotModeActive {
            MemoryInsightBackgroundService.shared.scheduleBackgroundTask()
            await MemoryInsightBackgroundService.shared.checkForegroundCompensation()
        }

        if InsightFeatureFlags.preferenceLearningEnabled {
            InsightFeedbackAggregator.shared.aggregate(in: CoreDataStack.shared.viewContext)
        }

        let repository = ThoughtRepository()
        repository.backfillTagAssignmentsIfNeeded()
        repository.normalizeExistingTags()
        ThoughtOrganizationQueue.shared.rebuildFromDatabase()
        Task { await ThoughtTagConvergenceJob.shared.resumePersistedJobIfNeeded() }

        await HoloWidgetSnapshotService.shared.refreshAllSnapshots()
        if HoloAIFeatureFlags.agentRuntimeEnabled {
            HoloBackgroundContinuationManager.shared.appDidLaunch()
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

    @State private var importPreviewData: ImportPreviewData?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var importResult: BatchImportResult?
    @State private var showImportResult = false
    @State private var parseTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let data = importPreviewData {
                ImportPreviewSheet(previewData: data) { result in
                    importResult = result
                    showImportResult = true
                }
            } else {
                ProgressView("正在解析文件...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.holoBackground)
            }
        }
        .onAppear {
            parseFile()
        }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
        }
        .alert("导入失败", isPresented: $showError) {
            Button("确定") { onDismiss() }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .alert("导入完成", isPresented: $showImportResult) {
            Button("确定") {
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                onDismiss()
            }
        } message: {
            if let result = importResult {
                Text("成功导入 \(result.successCount) 条交易\(result.failedItems.isEmpty ? "" : "，\(result.failedItems.count) 条失败")")
            }
        }
    }

    private func parseFile() {
        guard parseTask == nil else { return }
        let url = fileURL
        parseTask = Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let hasSecurityScope = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                    }
                    return try DataImportService.shared.parseCSV(url: url)
                }.value
                guard !Task.isCancelled else { return }
                importPreviewData = data
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "文件解析失败：\(error.localizedDescription)"
                showError = true
            }
            parseTask = nil
        }
    }
}
