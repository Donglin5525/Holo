//
//  DiscoveryEnvironmentProvider.swift
//  Holo
//
//  「一个发现」资源与环境快照采集（实施包 03 §4.3）。
//
//  OS 事实（热状态/低电量/低数据/网络可用性）在本文件采集；
//  用户活动（输入/录音/手动 AI）由调用方闭包注入——provider 不感知 UI 层。
//  纯读快照，不做任何诊断上报；调度决策归 DiscoverySchedulerCore。
//
//  · 网络可用性：NWPathMonitor 常驻监听，最新 path 经锁保护，snapshot() 任意线程可调。
//  · 低数据口径：path.isConstrained（Low Data Mode）或 isExpensive（蜂窝/热点）均视为
//    成本敏感（03 §4.3「低数据模式延后」的保守实现）。
//  · 热状态：fair 及以上均让位（nominal 之外全部算 thermally constrained）。
//

import Foundation
import Network

// MARK: - 用户活动注入

/// 调用方注入的用户活动状态（03 §4.3：输入、录音、手动 AI 运行中均延后）。
struct DiscoveryUserActivityState: Sendable, Equatable {
    var isTextInputActive = false
    var isRecording = false
    var isManualAIRunning = false

    init(isTextInputActive: Bool = false, isRecording: Bool = false, isManualAIRunning: Bool = false) {
        self.isTextInputActive = isTextInputActive
        self.isRecording = isRecording
        self.isManualAIRunning = isManualAIRunning
    }
}

// MARK: - 采集器

/// 资源快照采集器。线程安全（NWPathMonitor 回调在私有队列，状态经 NSLock 保护）。
nonisolated final class DiscoveryEnvironmentProvider {

    private let lock = NSLock()
    private var networkAvailable: Bool
    private var networkCostSensitive: Bool
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "holo.discovery.environment.monitor")
    private let activityProvider: @Sendable () -> DiscoveryUserActivityState

    init(activityProvider: @escaping @Sendable () -> DiscoveryUserActivityState = { DiscoveryUserActivityState() }) {
        self.networkAvailable = false
        self.networkCostSensitive = false
        self.activityProvider = activityProvider
        self.monitor = NWPathMonitor()
        // 初始 unsatisfied 到首个 path 更新之间视为不可用（保守：不抢跑）
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.networkAvailable = path.status == .satisfied
            self.networkCostSensitive = path.isConstrained || path.isExpensive
            self.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    /// 当前资源快照（组装为 DiscoverySchedulerCore.decide 的 resource 入参）。
    func snapshot() -> DiscoveryResourceSnapshot {
        lock.lock()
        let available = networkAvailable
        let costSensitive = networkCostSensitive
        lock.unlock()

        let activity = activityProvider()
        let processInfo = ProcessInfo.processInfo
        return DiscoveryResourceSnapshot(
            isTextInputActive: activity.isTextInputActive,
            isRecording: activity.isRecording,
            isManualAIRunning: activity.isManualAIRunning,
            isThermallyConstrained: processInfo.thermalState != .nominal,
            isLowPowerMode: processInfo.isLowPowerModeEnabled,
            isLowDataMode: costSensitive,
            isNetworkAvailable: available
        )
    }

    /// 前台激活轻量检查（03 §4.3：只决定是否安排 utility 任务，不阻塞主线程）。
    /// 功能开关/授权/材料资格的完整判定在 Coordinator.runBatch 的调度决策里做；
    /// 这里只看「此刻资源是否让位」。
    func foregroundCheck() -> DiscoveryForegroundCheckOutcome {
        let snapshot = snapshot()
        if snapshot.shouldYield || !snapshot.isNetworkAvailable {
            return .skip
        }
        return .scheduleUtilityCheck
    }
}
