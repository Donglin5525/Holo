//
//  OpenReviewIntent.swift
//  Holo
//
//  “始终先确认”模式的前台复核入口。
//

import AppIntents
import Foundation

struct OpenReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Holo 确认"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "草稿")
    var draftIDRaw: String?

    init() {}

    init(draftIDRaw: String?) {
        self.draftIDRaw = draftIDRaw
    }

    func perform() async throws -> some IntentResult {
        guard let raw = draftIDRaw, let draftID = UUID(uuidString: raw) else {
            return .result()
        }
        // 统一走 Presenter：导航同时落「已自动弹过」标记，用户关掉复核页后
        // 回前台兜底不再重复弹（与通知点击/前台直弹同一口径）
        await ReceiptBookingForegroundPresenter.present(draftID: draftID)
        return .result()
    }
}
