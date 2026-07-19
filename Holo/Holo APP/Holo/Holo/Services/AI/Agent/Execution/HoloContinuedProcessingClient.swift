//
//  HoloContinuedProcessingClient.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 6（§9.2/9.3）
//  iOS 26 持续处理能力的抽象层：生产 = BGTaskScheduler + BGContinuedProcessingTask，
//  测试 = 可注入 fake（模拟器无法真实调度，资格/提交/进度/取消语义全靠 fake 回归）。
//  编译门槛：本机 SDK ≥ iOS 26（已核实 Xcode 26.3 / iPhoneOS 26.2），直接引用 API，
//  运行时用 #available(iOS 26.0, *) 门控。
//

import Foundation
import BackgroundTasks

/// 系统持续处理请求（§9.3：提交策略 .fail —— 不接纳即回落，不把互动任务排队）。
struct HoloContinuedTaskRequest: Sendable, Equatable {
    var identifier: String
    var title: String
    var subtitle: String
    var strategy: Strategy

    enum Strategy: String, Sendable {
        case fail
        case queue
    }
}

/// 系统持续处理任务句柄的最小抽象（lease 据此更新进度/文案/结束任务）。
@MainActor
protocol HoloContinuedTask: AnyObject {
    var identifier: String { get }
    /// NSProgressReporting 进度对象（totalUnitCount/completedUnitCount）
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }
    /// 更新系统 Live Activity 标题/副标题（§7.4：只用通用文案）
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

/// 系统持续处理调度抽象（生产 BGTaskScheduler；测试 fake）。
@MainActor
protocol HoloContinuedProcessingClient: AnyObject {
    /// 注册 identifier 的启动闭包；返回 false 只表示系统拒绝注册。
    /// 生产实现会在同一 identifier 再次申请时复用系统注册，并更新本轮业务回调。
    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any HoloContinuedTask) -> Void
    ) -> Bool
    /// 提交请求；.fail 策略下系统不立即接纳将抛错（调用方回落 legacy/foreground）
    func submit(_ request: HoloContinuedTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
}

// MARK: - 生产实现（iOS 26+）

@available(iOS 26.0, *)
nonisolated final class HoloSystemContinuedProcessingClient: HoloContinuedProcessingClient {

    /// BGTaskScheduler 对同一 identifier 的第二次注册会直接终止 App。
    /// Continued Processing 虽允许动态注册，但同一 job 恢复执行时必须复用既有系统注册，
    /// 仅替换本轮 lease 的业务回调。
    private var registeredIdentifiers: Set<String> = []
    private var launchHandlers: [String: (any HoloContinuedTask) -> Void] = [:]

    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any HoloContinuedTask) -> Void
    ) -> Bool {
        launchHandlers[identifier] = launchHandler
        if registeredIdentifiers.contains(identifier) {
            return true
        }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            // client 与 lease 都是 MainActor；明确指定主队列，避免系统默认后台队列
            // 直接触碰 MainActor 状态与设置 expiration handler。
            using: .main
        ) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let self else {
                continued.setTaskCompleted(success: false)
                return
            }
            let wrapped = HoloSystemContinuedTask(task: continued)
            guard let handler = self.launchHandlers[identifier] else {
                wrapped.setTaskCompleted(success: false)
                return
            }
            handler(wrapped)
        }
        if registered {
            registeredIdentifiers.insert(identifier)
        } else {
            launchHandlers[identifier] = nil
        }
        return registered
    }

    func submit(_ request: HoloContinuedTaskRequest) throws {
        let systemRequest = BGContinuedProcessingTaskRequest(
            identifier: request.identifier,
            title: request.title,
            subtitle: request.subtitle
        )
        systemRequest.strategy = request.strategy == .fail ? .fail : .queue
        try BGTaskScheduler.shared.submit(systemRequest)
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@available(iOS 26.0, *)
// 包装器本身不做全局 actor 隔离；协议成员仍要求 MainActor 调用。
// 这样 lease 析构时不会形成 MainActor-isolated deinit 嵌套，规避 Swift 运行时
// TaskLocal::StopLookupScope 在 iOS 26.3 Simulator 已复现的非法释放路径。
nonisolated final class HoloSystemContinuedTask: HoloContinuedTask {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var identifier: String { task.identifier }
    var progress: Progress { task.progress }
    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
