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
        await DeepLinkState.shared.navigate(to: .receiptReview(draftID: draftID))
        return .result()
    }
}
