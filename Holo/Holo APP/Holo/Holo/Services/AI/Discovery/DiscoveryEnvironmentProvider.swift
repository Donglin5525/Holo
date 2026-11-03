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
//  · 低数据口径：仅 path.isConstrained（用户显式开启的 Low Data Mode）让位；
//    蜂窝/热点（isExpensive）2026-10-30 起不再算成本敏感——发现批次一天一次、
//    单次几分钱，蜂窝可负担；原口径致无 Wi-Fi 环境功能永不触发（真机实证）。
//  · 热状态：fair 及以上均让位（nominal 之外全部算 thermally constrained）。
//

import Foundation
import Network
import os

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
            // 仅用户显式低数据模式让位（2026-10-30 修正；蜂窝 isExpensive 不再算，
            // 否则无 Wi-Fi 环境下发现功能永不触发——真机 disp refresh: check=skip 实证）
            self.networkCostSensitive = path.isConstrained
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
    /// 2026-10-30 修正：蜂窝/热点（isExpensive）不再让位——「一个发现」一天一次、
    /// 单次调用几分钱+约百 KB 输入，蜂窝可负担；此前蜂窝=永久 skip，真机实证
    /// 功能在无 Wi-Fi 环境下永不触发（东林真机 disp refresh: check=skip 连续两轮）。
    /// 仅用户显式开启的低数据模式（isConstrained）仍让位。
    func foregroundCheck() -> DiscoveryForegroundCheckOutcome {
        let snapshot = snapshot()
        let logger = Logger(subsystem: "com.holo.app", category: "Discovery")
        let yieldReasons = [
            snapshot.isTextInputActive ? "input" : "",
            snapshot.isRecording ? "recording" : "",
            snapshot.isManualAIRunning ? "manualAI" : "",
            snapshot.isThermallyConstrained ? "thermal" : "",
            snapshot.isLowPowerMode ? "lowPower" : "",
            snapshot.isLowDataMode ? "lowData" : "",
            snapshot.isNetworkAvailable ? "" : "noNet",
        ].filter { !$0.isEmpty }.joined(separator: ",")
        logger.notice("disp env snapshot: yield=[\(yieldReasons, privacy: .public)] net=\(snapshot.isNetworkAvailable)")
        if !yieldReasons.isEmpty {
            return .skip
        }
        return .scheduleUtilityCheck
    }
}
