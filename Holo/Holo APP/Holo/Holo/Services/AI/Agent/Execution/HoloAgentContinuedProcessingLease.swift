//
//  HoloAgentContinuedProcessingLease.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 6（§9，L2 持续执行）
//  iOS 26 Continued Processing 租约：包装 BGContinuedProcessingTask，绑定具体 jobID。
//  - 提交策略 .fail（§9.3）：系统立即接纳才接管；不接纳回落 foreground/legacy；
//  - report 更新系统进度（§9.4：真实预算单位、单调不回退、retry 不加单位）；
//  - 标题固定通用文案，副标题只显示通用阶段（§7.4：不出现用户问题/健康指标/金额/工具摘要）；
//  - finish 立即 setTaskCompleted；提前完成直接补齐进度，不伪造中间百分比；
//  - 系统结束（expiration/取消）按 §9.5「不可区分」保守路径：结束本次 lease，
//    回调 Scheduler 落 paused + 来源，不自动复活（真机 spike 待办见 onSystemEnded 注释）。
//

import Foundation

/// §9.1 continued 资格矩阵（纯函数便于单测）：
/// iOS 26+（client 可用）/ 开关开启 / 已同意 AI 数据处理 / 用户明确发起 / 无其他 P0 持有 continued 执行权。
enum HoloAgentContinuedEligibility {
    static func isEligible(trigger: HoloAgentTrigger,
                           clientAvailable: Bool,
                           consentGranted: Bool,
                           flagEnabled: Bool,
                           hasActiveContinuedLease: Bool) -> Bool {
        clientAvailable
            && flagEnabled
            && consentGranted
            && trigger == .userQuestion
            && !hasActiveContinuedLease
    }
}

@MainActor
final class HoloAgentContinuedProcessingLease: HoloAgentExecutionLease {

    let kind: HoloAgentExecutionLeaseKind = .continuedProcessing
    /// 绑定的 jobID
    let jobID: String

    /// 系统 UI 固定标题（§7.4：通用文案，不含任何用户内容）
    static let taskTitle = "正在完成 Holo 深度分析"

    private let identifier: String
    private let client: any HoloContinuedProcessingClient
    private let onSystemEnded: @Sendable (String) -> Void
    private let initialTotalUnits: Int
    private let initialCompletedUnits: Int
    private var systemTask: (any HoloContinuedTask)?
    private var didFinish = false
    private var completionSuccess: Bool?
    /// progress 单调不回退（§9.4）
    private var lastCompletedUnits = 0

    /// 诊断用：系统是否已启动该任务
    private(set) var didLaunch = false

    init(jobID: String,
         client: any HoloContinuedProcessingClient,
         initialProgress: HoloAgentProgressSnapshot? = nil,
         onSystemEnded: @escaping @Sendable (String) -> Void) {
        self.jobID = jobID
        self.client = client
        self.onSystemEnded = onSystemEnded
        self.identifier = Self.identifier(for: jobID)
        self.initialTotalUnits = max(1, initialProgress?.totalUnitCount ?? 1)
        self.initialCompletedUnits = max(0, initialProgress?.completedUnitCount ?? 0)
    }

    /// permitted identifier：`$(PRODUCT_BUNDLE_IDENTIFIER).agent.continued.<jobID>`（§9.2）。
    /// Apple 要求每个具体工作使用唯一 task-name；不能只截 UUID 前 8 位，否则存在碰撞和误取消风险。
    static func identifier(for jobID: String) -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.holo.Holo"
        let safeSuffix = jobID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "-"
        }
        return "\(bundleID).agent.continued.\(String(safeSuffix))"
    }

    /// 注册 + 提交（.fail）：系统立即接纳返回 true；注册已存在继续复用（§9.2 同一 identifier 只注册一次）。
    /// 不接纳（submit 抛错）返回 false，调用方回落 foreground/legacy（§9.3）。
    func acquire() -> Bool {
        guard !didFinish else { return false }
        // 生产 client 会安全复用同一 identifier 的系统注册；false 只表示 Info.plist/系统拒绝注册。
        guard client.register(forTaskWithIdentifier: identifier, launchHandler: { [weak self] task in
            self?.systemDidLaunch(task)
        }) else { return false }
        do {
            try client.submit(HoloContinuedTaskRequest(
                identifier: identifier,
                title: Self.taskTitle,
                subtitle: Self.subtitle(completedUnits: initialCompletedUnits),
                strategy: .fail
            ))
            return true
        } catch {
            return false
        }
    }

    /// §9.4：每次 checkpoint 后上报一次。进度用真实预算单位，单调不回退；
    /// 副标题只来自固定模板（通用阶段，无敏感内容）。
    func report(_ progress: HoloAgentProgressSnapshot) async {
        guard !didFinish, let systemTask else { return }
        let total = max(1, Int(systemTask.progress.totalUnitCount), progress.totalUnitCount)
        let completed = min(total, max(lastCompletedUnits, progress.completedUnitCount))
        lastCompletedUnits = completed
        systemTask.progress.totalUnitCount = Int64(total)
        systemTask.progress.completedUnitCount = Int64(completed)
        systemTask.updateTitle(Self.taskTitle, subtitle: Self.subtitle(completedUnits: completed))
    }

    /// job 终态：立即结束系统任务（§6.3：不等待场景回前台或系统 expiration）。
    /// §9.4：提前完成直接补齐进度并结束，不伪造中间百分比。
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
            // 请求可能已提交但 launch handler 仍未回调；先撤销 pending request。
            client.cancel(taskRequestWithIdentifier: identifier)
        }
        systemTask = nil
    }

    // MARK: - 系统回调

    /// 系统启动任务（register 的 launchHandler 经 client 调用）。
    private func systemDidLaunch(_ launchedTask: any HoloContinuedTask) {
        configureInitialProgress(on: launchedTask)
        if didFinish {
            // submit 成功后 job 可能极快完成，launch 回调晚到。系统任务仍必须闭合，不能悬挂。
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

    /// §9.5：系统结束（expiration/取消）。真机 spike 待办：当前 SDK/真机上系统取消与资源
    /// expiration 是否可区分尚未验证，按「不可区分」保守路径——结束本次 execution lease，
    /// 回调 Scheduler 落 paused + 来源，不自动悄悄复活；用户回前台由恢复链/明确动作接管。
    private func systemDidExpire() {
        guard !didFinish else { return }
        didFinish = true
        completionSuccess = false
        // Apple 要求 expiration handler 尽快结束系统任务；只取消本地 runLoop 不足以归还系统资源。
        let expiredTask = systemTask
        systemTask = nil
        expiredTask?.expirationHandler = nil
        expiredTask?.setTaskCompleted(success: false)
        onSystemEnded(jobID)
    }

    /// task 一启动就设置可衡量的真实预算，避免等待第一轮 LLM 时 progress 仍是未定义/0 而被判定停滞。
    private func configureInitialProgress(on task: any HoloContinuedTask) {
        let completed = min(initialTotalUnits, max(lastCompletedUnits, initialCompletedUnits))
        lastCompletedUnits = completed
        task.progress.totalUnitCount = Int64(initialTotalUnits)
        task.progress.completedUnitCount = Int64(completed)
        task.updateTitle(Self.taskTitle, subtitle: Self.subtitle(completedUnits: completed))
    }

    /// 系统副标题：只显示通用阶段（§7.4：不出现用户问题/健康指标/金额/工具摘要）。
    static func subtitle(completedUnits: Int) -> String {
        completedUnits > 0 ? "第 \(completedUnits) 轮分析" : "正在整理证据"
    }
}
