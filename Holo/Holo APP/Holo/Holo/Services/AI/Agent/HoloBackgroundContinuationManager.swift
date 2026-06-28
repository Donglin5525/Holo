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
final class HoloBackgroundContinuationManager {

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let runtime: HoloLocalAgentRuntime
    private var resumeTask: Task<Void, Never>?

    init(runtime: HoloLocalAgentRuntime) {
        self.runtime = runtime
    }

    /// App 进入后台：cancel 在途续跑 + 标记 job 为可恢复。
    func appDidEnterBackground() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HoloAgentFinish") { [weak self] in
            self?.endBackgroundTask()
        }
        // Phase 1 CAS：取消在途续跑 Task，避免后台继续跑浪费 token
        resumeTask?.cancel()
        Task { [runtime] in
            try? await runtime.pauseForBackground()
            await MainActor.run { self.endBackgroundTask() }
        }
    }

    /// App 即将回前台：cancel 旧续跑（如果有）+ 经 Scheduler 重启未完成 job 的 runLoop（闭合 N1）。
    func appWillEnterForeground() {
        resumeTask?.cancel()
        let scheduler = HoloAgentScheduler.shared
        resumeTask = Task { [runtime, scheduler] in
            let toolDescriptions = await runtime.toolDescriptions()
            let systemTemplate = (try? await PromptManager.shared.loadPrompt(.agentLoop)) ?? ""
            _ = try? await scheduler.resumeAndContinue(
                systemTemplate: systemTemplate, toolDescriptions: toolDescriptions
            )
            _ = try? await scheduler.cleanupTerminalJobs()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
