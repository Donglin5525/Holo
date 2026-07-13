//
//  HoloBackgroundContinuationManager.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 5.1 后台续跑管理
//  适配 iOS 生命周期：进后台时让 runtime 暂存 checkpoint，回前台时恢复未完成任务。
//  仅在 HoloAIFeatureFlags.agentRuntimeEnabled 开启时由 App 注册。
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

@MainActor
final class HoloBackgroundContinuationManager {

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let runtime: HoloLocalAgentRuntime
    private let scheduler: HoloAgentScheduler
    private let backgroundTaskClient: any HoloBackgroundTaskClient
    private var resumeTask: Task<Void, Never>?
    private var didExpireInBackground = false

    init(runtime: HoloLocalAgentRuntime,
         scheduler: HoloAgentScheduler? = nil,
         backgroundTaskClient: (any HoloBackgroundTaskClient)? = nil) {
        self.runtime = runtime
        self.scheduler = scheduler ?? HoloAgentScheduler(runtime: runtime)
        self.backgroundTaskClient = backgroundTaskClient ?? UIApplicationBackgroundTaskClient()
    }

    /// App 进入后台：申请 iOS 后台执行时间，让在途 Agent 继续推进。
    /// 只有系统到期回调触发时才落盘为 waitingForForeground，避免刚切后台就中断用户发起的 Agent。
    func appDidEnterBackground() {
        if backgroundTaskID != .invalid {
            endBackgroundTask()
        }
        backgroundTaskID = backgroundTaskClient.beginBackgroundTask(named: "HoloAgentFinish") { [weak self] in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.pauseForBackgroundExpiration()
            }
        }
        resumeTask?.cancel()
        didExpireInBackground = false
    }

    /// App 即将回前台：快速切回只同步 Chat 状态；后台时间到期暂停过才重启 runLoop。
    func appWillEnterForeground() {
        endBackgroundTask()
        if didExpireInBackground {
            didExpireInBackground = false
            resumeAndSyncRecoveredJobs()
        } else {
            resumeTask?.cancel()
            resumeTask = Task {
                _ = await HoloAgentAnalysisService().syncRecoverableChatMessages()
            }
        }
    }

    /// 冷启动/进程被杀后重新启动：没有旧进程内 runLoop，可直接恢复未完成 job。
    func appDidLaunch() {
        resumeAndSyncRecoveredJobs()
    }

    private func resumeAndSyncRecoveredJobs() {
        resumeTask?.cancel()
        resumeTask = Task { [runtime, scheduler] in
            let toolDescriptions = await runtime.toolDescriptions()
            let systemTemplate = ""
            _ = try? await scheduler.resumeAndContinue(
                systemTemplate: systemTemplate, toolDescriptions: toolDescriptions
            )
            _ = await HoloAgentAnalysisService().syncRecoverableChatMessages()
            _ = try? await scheduler.cleanupTerminalJobs()
        }
    }

    private func pauseForBackgroundExpiration() {
        didExpireInBackground = true
        Task { [runtime] in
            try? await runtime.pauseForBackground()
            await MainActor.run { self.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        backgroundTaskClient.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
