//
//  HoloBackgroundContinuationManager.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 5.1 后台续跑管理
//  适配 iOS 生命周期：进后台时让 runtime 暂存 checkpoint，回前台时恢复未完成任务。
//  仅在 HoloAIFeatureFlags.agentRuntimeEnabled 开启时由 App 注册。
//
//  Holo Agent 稳定执行 — Phase 5（§6.3/§十 Phase 5 任务 6）
//  本类已收缩为「生命周期转发」：场景事件转给 Scheduler（唯一执行权/租约协调器），
//  不再直接持有后台任务、不再直接改 Runtime 状态。
//  后台租约实现见 Execution/HoloAgentLegacyBackgroundLease（绑定具体 jobID）。
//

import UIKit
import Foundation

@MainActor
protocol HoloBackgroundTaskClient {
    func beginBackgroundTask(named name: String, expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIApplicationBackgroundTaskClient: HoloBackgroundTaskClient {
    func beginBackgroundTask(named name: String, expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class HoloBackgroundTaskLease {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private let client: any HoloBackgroundTaskClient
    private let onExpiration: (() -> Void)?

    init(
        name: String,
        client: (any HoloBackgroundTaskClient)? = nil,
        onExpiration: (() -> Void)? = nil
    ) {
        self.client = client ?? UIApplicationBackgroundTaskClient()
        self.onExpiration = onExpiration
        self.taskID = self.client.beginBackgroundTask(named: name) { [weak self] in
            Task { @MainActor [weak self] in
                self?.expire()
            }
        }
    }

    deinit {
        let taskID = taskID
        let client = client
        guard taskID != .invalid else { return }
        Task { @MainActor in
            client.endBackgroundTask(taskID)
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        client.endBackgroundTask(taskID)
        taskID = .invalid
    }

    private func expire() {
        onExpiration?()
        end()
    }
}

/// 生命周期转发器（Phase 5 收缩后）：只把场景事件转给 Scheduler 与恢复链。
@MainActor
final class HoloBackgroundContinuationManager {

    private let runtime: HoloLocalAgentRuntime
    private let scheduler: HoloAgentScheduler
    private let reconciler: HoloAgentConsistencyReconciler
    private let eventRecorder: any HoloAgentEventRecording
    private var resumeTask: Task<Void, Never>?

    init(runtime: HoloLocalAgentRuntime,
         scheduler: HoloAgentScheduler? = nil,
         backgroundTaskClient: (any HoloBackgroundTaskClient)? = nil,
         reconciler: HoloAgentConsistencyReconciler? = nil,
         eventRecorder: any HoloAgentEventRecording = HoloNoopAgentEventRecorder.shared) {
        self.runtime = runtime
        // §6.3：后台任务 client 经 Scheduler 注入租约实现（生产 UIApplication，测试 fake）
        self.scheduler = scheduler ?? HoloAgentScheduler(
            runtime: runtime,
            backgroundTaskClient: backgroundTaskClient
        )
        self.reconciler = reconciler ?? HoloAgentConsistencyReconciler(persistence: runtime.persistence)
        self.eventRecorder = eventRecorder
    }

    /// App 进入后台：由 Scheduler 为活跃 job 申请绑定 jobID 的 legacy 租约。
    /// 系统到期（lease expiration）才暂停任务，避免刚切后台就中断用户发起的 Agent。
    func appDidEnterBackground() {
        resumeTask?.cancel()
        Task { [scheduler] in
            await scheduler.sceneDidEnterBackground()
        }
    }

    /// App 即将回前台：有租约被系统到期过才走恢复链；快速切回只同步 Chat 状态（既有任务继续）。
    func appWillEnterForeground() {
        Task { [scheduler] in
            let expired = await scheduler.sceneWillEnterForeground()
            await MainActor.run {
                if expired {
                    self.resumeAndSyncRecoveredJobs(trigger: .foreground)
                } else {
                    self.resumeTask?.cancel()
                    self.resumeTask = Task {
                        _ = await HoloAgentAnalysisService().syncRecoverableChatMessages()
                    }
                }
            }
        }
    }

    /// 冷启动/进程被杀后重新启动：没有旧进程内 runLoop 与旧租约，可直接恢复未完成 job。
    /// §5.4：resume 之前先跑一致性修复（半完成状态对齐），失败只记录日志不阻塞启动。
    func appDidLaunch() {
        resumeAndSyncRecoveredJobs(trigger: .appLaunch, reconcileFirst: true)
    }

    /// 设备解锁（protected data 可用）：等待 deviceUnlock 的任务由 Scheduler 重新评估恢复（§7.2）。
    /// 复用恢复链（resumeEligibleJobs 会按优先级拉起 waitingForCondition/waitingForForeground 任务）。
    func protectedDataDidBecomeAvailable() {
        resumeAndSyncRecoveredJobs(trigger: .foreground)
    }

    /// 恢复未完成 job 并同步 Chat 状态。§6.1：恢复统一走 Scheduler 唯一执行权（resumeEligibleJobs）。
    private func resumeAndSyncRecoveredJobs(trigger: HoloAgentResumeTrigger, reconcileFirst: Bool = false) {
        resumeTask?.cancel()
        resumeTask = Task { [runtime, scheduler, reconciler, eventRecorder] in
            if reconcileFirst {
                do {
                    let report = try await reconciler.reconcile()
                    if report.hasFixes {
                        await eventRecorder.record(HoloAgentTelemetryEvent(
                            name: .resultReconciled,
                            errorCode: "STARTUP_CONSISTENCY_REPAIR"
                        ))
                        NSLog("[Agent] 启动一致性修复完成: \(report)")
                    }
                } catch {
                    NSLog("[Agent] 启动一致性修复失败（不阻塞启动）: \(String(describing: error))")
                }
            }
            guard !Task.isCancelled else { return }
            let toolDescriptions = await runtime.toolDescriptions()
            let systemTemplate = ""
            do {
                _ = try await scheduler.resumeEligibleJobs(
                    trigger: trigger,
                    systemTemplate: systemTemplate,
                    toolDescriptions: toolDescriptions
                )
            } catch {
                NSLog("[Agent] 恢复未完成 job 失败: \(String(describing: error))")
            }
            _ = await HoloAgentAnalysisService().syncRecoverableChatMessages()
            do {
                _ = try await scheduler.cleanupTerminalJobs()
            } catch {
                NSLog("[Agent] 终态 job 清理失败: \(String(describing: error))")
            }
        }
    }
}
