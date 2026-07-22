//
//  HoloStartupCoordinator.swift
//  Holo
//
//  将冷启动工作按用户可见时机分段，并保证 SwiftUI View 重建不会重复执行一次性任务。
//

import Foundation

@MainActor
final class HoloStartupCoordinator {
    enum Stage: String, Hashable {
        case critical
        case afterFirstFrame
        case backgroundBestEffort
    }

    struct StageMetric: Equatable {
        let stage: Stage
        let duration: Duration
        let completedAt: Date
    }

    static let shared = HoloStartupCoordinator()

    private var completedStages: Set<Stage> = []
    private var runningStages: Set<Stage> = []
    private(set) var metrics: [StageMetric] = []

    init() {}

    /// 必须在首屏前完成的轻量注册。重复创建 App/Scene 时不会再次执行。
    func runCriticalOnce(_ operation: () -> Void) {
        guard begin(.critical) else { return }
        let clock = ContinuousClock()
        let start = clock.now
        operation()
        finish(.critical, duration: start.duration(to: clock.now))
    }

    /// 首帧出现后执行的一次性准备工作；调用方可继续把非关键任务拆到后台阶段。
    func runOnce(_ stage: Stage, operation: () async -> Void) async {
        guard begin(stage) else { return }
        let clock = ContinuousClock()
        let start = clock.now
        await operation()
        finish(stage, duration: start.duration(to: clock.now))
    }

    func hasCompleted(_ stage: Stage) -> Bool {
        completedStages.contains(stage)
    }

    private func begin(_ stage: Stage) -> Bool {
        guard !completedStages.contains(stage), !runningStages.contains(stage) else { return false }
        runningStages.insert(stage)
        return true
    }

    private func finish(_ stage: Stage, duration: Duration) {
        runningStages.remove(stage)
        completedStages.insert(stage)
        metrics.append(StageMetric(stage: stage, duration: duration, completedAt: Date()))
    }
}
