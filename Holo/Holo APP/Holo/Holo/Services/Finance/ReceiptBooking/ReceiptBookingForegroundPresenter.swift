//
//  ReceiptBookingForegroundPresenter.swift
//  Holo
//
//  图片快捷指令自动记账 · 确认页必达（2026-09-22）
//
//  痛点：确认页的到达原来只挂在两个系统拉起通道上——opensIntent（后台自动化
//  运行受系统策略限制，不保证拉起 App）与通知点击。用户完成记账后从横幅、
//  图标、多任务任何一路回到 Holo 时，App 只是恢复退出前的界面，待确认的账
//  看不见，操作链路断在最后一步。
//
//  根治：把「有未确认的账」当成 App 的持久状态，回前台这一刻统一兜底——
//  只要存在尚未自动弹过的待复核草案，就把复核页推到用户面前，不依赖任何
//  单一拉起通道。
//
//  不打扰边界（2026-09-23 收紧，东林实锤拍板）：自动弹出只服务「刚识别完」
//  的场景——只弹 10 分钟内新建的草案。反例：识别被拒后回 Holo，历史遗留草案
//  被当成这次的结果弹出来（复核页当时不显示识别时间），用户把昨天的 65 元
//  草案误当成今天识别的金额。旧草案绝不自动弹，只走复核列表与绑定该草案的
//  兜底通知；确认页展示识别时间让来源可辨。每个草案只自动弹一次（关掉复核页
//  = 暂不处理的明确信号）。
//

import Foundation

@MainActor
enum ReceiptBookingForegroundPresenter {

    /// 最近一次自动弹过的草案（uuidString）。回前台检查用它去重，避免反复打扰。
    private static let lastPresentedKey = "receiptBookingLastAutoPresentedDraftID"

    /// 「刚识别完」的判定窗口：草案创建在该窗口内才允许回前台自动弹出。
    /// 覆盖「识别完马上回 Holo」的正常路径；更早的草案交给复核列表与兜底通知。
    static let freshDraftPresentationWindow: TimeInterval = 10 * 60

    /// 弹出指定草案的复核页并落去重标记。
    /// 所有自动触达（回前台兜底 / opensIntent / 通知点击 / 前台直弹）统一走这里，
    /// 保证「关掉后不再自动弹」的口径全链一致。
    static func present(draftID: UUID) {
        UserDefaults.standard.set(draftID.uuidString, forKey: lastPresentedKey)
        DeepLinkState.shared.navigate(to: .receiptReview(draftID: draftID))
    }

    /// 回前台兜底检查：最新草案是「刚识别完」且未自动弹过时才弹。
    /// 草案盘上即事实（每次读磁盘、无缓存），确认/放弃即删，7 天过期。
    static func presentIfNeeded() {
        guard let latest = ReceiptBookingResultStore.shared.loadDrafts().first else { return }
        guard isFreshlyCreated(latest.createdAt, now: Date()) else { return }
        guard latest.id.uuidString != UserDefaults.standard.string(forKey: lastPresentedKey) else { return }
        present(draftID: latest.id)
    }

    /// 纯判定供单测锁定：窗口内创建（且非未来时间）才算「刚识别完」。
    /// 注意只看最新一条——旧草案排在后面时绝不逐条翻找可弹对象。
    nonisolated static func isFreshlyCreated(_ createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= freshDraftPresentationWindow
    }
}
