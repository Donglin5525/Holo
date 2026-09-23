//
//  MatterDemoSeed.swift
//  Holo
//
//  DEBUG-only 合成数据：模拟器纵向验收用（方案 M1 出口「日本旅行主旅程可在合成数据下端到端跑通」）。
//  启动参数 -MatterDemoSeed 触发；幂等（同标题 active Matter 已存在即跳过）。
//  真机/生产不可达（#if DEBUG + 显式启动参数双门禁）。
//

#if DEBUG
import Foundation

@MainActor
enum MatterDemoSeed {

    static let launchArgument = "-MatterDemoSeed"

    /// R4-2 诊断（临时）：种子静默失败无证据可查，追加写沙盒 tmp 文件供 Mac 侧读取
    private static func diag(_ line: String) {
        let path = NSTemporaryDirectory() + "matter-seed-diag.log"
        let stamped = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? stamped.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
    }

    static func seedIfNeeded() async {
        diag("invoked args=\(ProcessInfo.processInfo.arguments.contains(launchArgument)) storage=\(HoloMatterRolloutPolicy.storageEnabled)")
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        guard HoloMatterRolloutPolicy.storageEnabled else { return }
        let repo = HoloMatterRepository.shared

        // 清后种：保证每次带参启动都从确定的初始状态开始（UI 走查可重复）
        do {
            try await repo.deleteAllMattersForDemo()
        } catch {
            diag("deleteAllMattersForDemo FAILED: \(error)")
            return
        }

        let created: HoloMatter
        do {
            created = try await repo.createManualMatter(title: "国庆日本旅行", targetDate: Calendar.current.date(byAdding: .day, value: 20, to: Date()))
        } catch {
            diag("createManualMatter FAILED: \(error)")
            return
        }
        let matter = created
        diag("matter created id=\(matter.id.uuidString)")

        // 已确认的问题（confirmed）：猫咪照护、京都住宿
        let catLoop = try? await repo.addSuggestedOpenLoop(matterID: matter.id, draft: .init(logicalKey: "猫咪由谁照顾", title: "猫咪由谁照顾"))
        let kyotoLoop = try? await repo.addSuggestedOpenLoop(matterID: matter.id, draft: .init(logicalKey: "预订京都住宿", title: "预订京都住宿"))
        let visaLoop = try? await repo.addSuggestedOpenLoop(
            matterID: matter.id,
            draft: .init(logicalKey: "确认签证材料", title: "确认签证材料", targetDate: Calendar.current.date(byAdding: .day, value: 10, to: Date()))
        )
        // 用户确认（confirmed 语义来自用户动作）
        for loop in [catLoop, kyotoLoop, visaLoop].compactMap({ $0 }) {
            try? await repo.confirmOpenLoop(id: loop.id)
        }

        // AI 建议的问题（suggested，虚线弱化）
        _ = try? await repo.addSuggestedOpenLoop(matterID: matter.id, draft: .init(logicalKey: "买转换插头", title: "买转换插头"))

        // 已解决：东京住宿（用户在对话里确认 → assistant 自动应用 → 可撤销）
        if let tokyoLoop = try? await repo.addSuggestedOpenLoop(matterID: matter.id, draft: .init(logicalKey: "预订东京住宿", title: "预订东京住宿")) {
            try? await repo.confirmOpenLoop(id: tokyoLoop.id)
            try? await repo.setOpenLoopState(id: tokyoLoop.id, state: .resolved, actor: .assistant, sourceRevision: "demo-msg-1", sourceType: "chatMessage")
        }

        // 相关任务链接（示意）
        _ = try? await repo.addLink(matterID: matter.id, entityType: .todoTask, entityID: "demo-task-visa", role: .action, origin: .system)

        // 确定性投影
        let coordinator = HoloMatterReconciliationCoordinator()
        await coordinator.refreshProjection(matterID: matter.id)
    }
}
#endif
