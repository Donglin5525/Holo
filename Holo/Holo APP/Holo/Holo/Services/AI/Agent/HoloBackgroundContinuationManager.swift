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
final class HoloBackgroundContinuationManager {

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let runtime: HoloLocalAgentRuntime
    private let backgroundTaskClient: any HoloBackgroundTaskClient
    private var resumeTask: Task<Void, Never>?

    init(runtime: HoloLocalAgentRuntime,
         backgroundTaskClient: (any HoloBackgroundTaskClient)? = nil) {
        self.runtime = runtime
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
    }

    /// App 即将回前台：cancel 旧续跑（如果有）+ 经 Scheduler 重启未完成 job 的 runLoop（闭合 N1）。
    func appWillEnterForeground() {
        endBackgroundTask()
        resumeTask?.cancel()
        let scheduler = HoloAgentScheduler.shared
        resumeTask = Task { [runtime, scheduler] in
            let toolDescriptions = await runtime.toolDescriptions()
            let systemTemplate = (try? PromptManager.shared.loadPrompt(.agentLoop)) ?? ""
            _ = try? await scheduler.resumeAndContinue(
                systemTemplate: systemTemplate, toolDescriptions: toolDescriptions
            )
            await HoloAgentAnalysisService().finalizeRecoveredChatMessages()
            _ = try? await scheduler.cleanupTerminalJobs()
        }
    }

    private func pauseForBackgroundExpiration() {
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
