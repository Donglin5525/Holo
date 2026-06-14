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

    init(runtime: HoloLocalAgentRuntime) {
        self.runtime = runtime
    }

    /// App 进入后台：申请后台时间，让 runtime 把运行中任务标记为可恢复。
    func appDidEnterBackground() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HoloAgentFinish") { [weak self] in
            self?.endBackgroundTask()
        }
        Task { [runtime] in
            try? await runtime.pauseForBackground()
            await MainActor.run { self.endBackgroundTask() }
        }
    }

    /// App 即将回前台：恢复所有未结束任务。
    func appWillEnterForeground() {
        Task { [runtime] in
            _ = try? await runtime.resumeUnfinishedJobs()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
