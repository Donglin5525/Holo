//
//  ReceiptBookingResultSurfacer.swift
//  Holo
//
//  图片快捷记账 · 结果播报必达（2026-10-14）
//
//  痛点：拒识（转账截图等）与失败的结果反馈原来只有系统通知一条通道——
//  通知权限未授权/未请求时 notifyIfNeeded 静默跳过，用户什么都看不到，
//  以为记上了或以为功能坏了（东林 10-14 实锤：「至少要弹出来告诉用户
//  这笔交易不入账」）。
//
//  根治：把「刚产生的识别结果」当成回到 App 时必须交代的账——用悬浮窗
//  toast（OverlayWindowController 独立窗口，盖在一切页面与弹层之上）兜底
//  播报，不依赖通知权限。文案与既有通知/快捷指令结果文字共用同一份口径，
//  不新增 xcstrings 词条（既有词条以「：」拼接）。
//
//  分工：needsReview 不走此通道（复核页本身必达，见 ForegroundPresenter）；
//  undone 是用户自己在 App 里撤销的，无需播报；rejected 中 reasonCode 为空
//  的是「删除待复核」的操作留痕，同样不播报。
//

import Foundation
import os.log

@MainActor
enum ReceiptBookingResultSurfacer {

    private static let logger = Logger(subsystem: "com.holo.app", category: "ReceiptBookingSurfacer")

    /// 最近一次已播报的结果（uuidString）。回前台检查用它去重，一条结果只播一次。
    private static let lastSurfacedKey = "receiptBookingLastSurfacedResultID"

    /// 「刚产生」的判定窗口：与草案直弹窗口同口径（10 分钟），
    /// 只服务「刚识别完回到 App」的场景，历史结果不翻旧账。
    nonisolated static let freshResultWindow: TimeInterval = 10 * 60

    /// 回前台/识别刚结束时检查：最新结果是「刚产生的」且未播报过才弹 toast。
    /// 结果流最新在前（append 恒插队首），只看第一条，不逐条翻找。
    @discardableResult
    static func surfaceIfNeeded(now: Date = Date()) -> Bool {
        let latest = ReceiptBookingResultStore.shared.loadResults().first
        guard let latest,
              Self.shouldSurface(
                latest: latest,
                lastSurfacedID: UserDefaults.standard.string(forKey: lastSurfacedKey),
                now: now
              ),
              let toast = Self.message(for: latest) else {
            logger.info("skip surface: latest=\(latest.map { "\($0.id.uuidString) kind=\($0.kind.rawValue) age=\(Int(now.timeIntervalSince($0.createdAt)))s" } ?? "nil", privacy: .public)")
            return false
        }
        acknowledge(resultID: latest.id)
        logger.info("surface result \(latest.id.uuidString, privacy: .public): \(toast.text, privacy: .public)")
        HoloToastCenter.shared.show(toast.text, type: toast.type, duration: 5)
        return true
    }

    /// 落「已播报」标记。
    static func acknowledge(resultID: UUID) {
        UserDefaults.standard.set(resultID.uuidString, forKey: lastSurfacedKey)
    }

    /// 纯判定供单测锁定：最新结果是否该播报（窗口内 + 未播过 + 属于该播的种类）。
    nonisolated static func shouldSurface(
        latest: ReceiptBookingResultStore.StoredResult?,
        lastSurfacedID: String?,
        now: Date
    ) -> Bool {
        guard let latest, isFresh(latest.createdAt, now: now) else { return false }
        guard latest.id.uuidString != lastSurfacedID else { return false }
        return message(for: latest) != nil
    }

    /// 纯判定供单测锁定：窗口内创建（且非未来时间）才算「刚产生」。
    nonisolated static func isFresh(_ createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= freshResultWindow
    }

    /// 纯构造播报文案（不碰 UI，供单测锁定）；nil = 该结果不走 toast 通道。
    nonisolated static func message(
        for result: ReceiptBookingResultStore.StoredResult
    ) -> (text: String, type: ToastType)? {
        switch result.kind {
        case .rejected:
            guard let code = result.reasonCode,
                  let reason = ReceiptBookingReason(rawValue: code) else { return nil }
            return (String(localized: "这笔没有入账") + "：" + reason.rejectionUserText, .warning)
        case .failed:
            let detail: String
            if result.reasonCode == ReceiptBookingReason.failureRateLimited.rawValue {
                detail = String(localized: "今天的识别次数用完了，明天再试。")
            } else {
                detail = String(localized: "截图仍在照片里，可稍后重试。")
            }
            return (String(localized: "记账没有成功") + "：" + detail, .error)
        case .duplicate:
            guard let summary = result.summaryText, !summary.isEmpty else { return nil }
            return (String(localized: "这张图已经记过") + "：" + summary, .info)
        case .booked:
            guard let summary = result.summaryText, !summary.isEmpty else { return nil }
            return (summary, .success)
        case .undone, .needsReview:
            return nil
        }
    }
}
