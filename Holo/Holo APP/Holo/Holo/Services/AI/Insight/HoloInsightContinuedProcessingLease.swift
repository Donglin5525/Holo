//
//  HoloInsightContinuedProcessingLease.swift
//  Holo
//
//  周期回放的 iOS 26 Continued Processing 租约
//  复用 HoloContinuedProcessingClient（与 Agent 共享的系统抽象层），
//  但不绑定 Agent jobID/Scheduler，针对单次洞察生成的"生成中 → 完成"语义。
//
//  效果：用户点"周期回放"后，可切走/息屏，生成在后台继续；
//  系统在锁屏/灵动岛区域显示"正在生成 Holo 回放"进度，完成即消失。
//
//  约束：
//  - iOS 26+ 真机才生效（模拟器 BGTaskScheduler 无法真实调度）
//  - 单次洞察生成（10-40s）属于短任务，系统可能不接纳 continued request（.fail 被拒）；
//    不接纳时静默回落前台执行，不影响功能
//

import Foundation

@MainActor
final class HoloInsightContinuedProcessingLease {

    /// 系统 UI 固定标题（通用文案，不含用户数据）
    static let taskTitle = "正在生成 Holo 回放"

    private let identifier: String
    private let client: any HoloContinuedProcessingClient
    private let onExpiration: () -> Void
    private var systemTask: (any HoloContinuedTask)?
    private var didFinish = false
    private var completionSuccess: Bool?

    /// 诊断用：系统是否已启动该任务
    private(set) var didLaunch = false

    init(requestID: String,
         client: any HoloContinuedProcessingClient,
         onExpiration: @escaping () -> Void = {}) {
        self.identifier = Self.identifier(for: requestID)
        self.client = client
        self.onExpiration = onExpiration
    }

    /// permitted identifier：复用 Agent 的 continued 命名空间（白名单已含通配符）
    static func identifier(for requestID: String) -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.holo.Holo"
        let safeSuffix = requestID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "-"
        }
        return "\(bundleID).agent.continued.\(String(safeSuffix))"
    }

    /// 注册 + 提交（.fail）：系统立即接纳返回 true；不接纳返回 false（调用方回落前台）。
    @discardableResult
    func acquire() -> Bool {
        guard !didFinish else { return false }
        guard client.register(forTaskWithIdentifier: identifier, launchHandler: { [weak self] task in
            self?.systemDidLaunch(task)
        }) else { return false }
        do {
            try client.submit(HoloContinuedTaskRequest(
                identifier: identifier,
                title: Self.taskTitle,
                subtitle: "正在回顾这段时间的记录",
                strategy: .fail
            ))
            return true
        } catch {
            return false
        }
    }

    /// 更新系统进度文案（洞察生成是单次调用，无中间轮次，这里只更新副标题）。
    func report(subtitle: String) async {
        guard !didFinish, let systemTask else { return }
        systemTask.updateTitle(Self.taskTitle, subtitle: subtitle)
    }

    /// 生成结束：立即结束系统任务。
    func finish(success: Bool) async {
        guard !didFinish else { return }
        didFinish = true
        completionSuccess = success
        if let systemTask {
            if success {
                systemTask.progress.completedUnitCount = systemTask.progress.totalUnitCount
            }
            systemTask.expirationHandler = nil
            systemTask.setTaskCompleted(success: success)
        } else {
            // 请求可能已提交但 launch handler 仍未回调；撤销 pending request。
            client.cancel(taskRequestWithIdentifier: identifier)
        }
        systemTask = nil
    }

    // MARK: - 系统回调

    private func systemDidLaunch(_ launchedTask: any HoloContinuedTask) {
        // 初始进度：总量 1，已完成 0
        launchedTask.progress.totalUnitCount = 1
        launchedTask.progress.completedUnitCount = 0
        launchedTask.updateTitle(Self.taskTitle, subtitle: "正在回顾这段时间的记录")

        if didFinish {
            // submit 成功后生成可能极快完成，launch 回调晚到。系统任务仍必须闭合。
            let success = completionSuccess ?? false
            if success {
                launchedTask.progress.completedUnitCount = launchedTask.progress.totalUnitCount
            }
            launchedTask.setTaskCompleted(success: success)
            return
        }
        didLaunch = true
        launchedTask.expirationHandler = { [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                self.systemDidExpire()
            }
        }
        systemTask = launchedTask
    }

    /// 系统结束（expiration/取消）：标记结束，不自动复活。
    private func systemDidExpire() {
        guard !didFinish else { return }
        didFinish = true
        completionSuccess = false
        let expiredTask = systemTask
        systemTask = nil
        expiredTask?.expirationHandler = nil
        expiredTask?.setTaskCompleted(success: false)
        onExpiration()
    }
}
