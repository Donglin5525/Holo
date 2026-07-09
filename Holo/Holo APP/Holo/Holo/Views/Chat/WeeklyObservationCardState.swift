//
//  WeeklyObservationCardState.swift
//  Holo
//
//  「本周观察」卡片的本地交互状态。与持久化观察数据分离，确保关闭和重试立即反馈。
//

import Foundation

struct WeeklyObservationCardState: Equatable {
    private(set) var isDismissed = false
    private(set) var isRetrying = false
    private(set) var errorMessage: String?
    private(set) var revision = 0

    init(isDismissed: Bool = false) {
        self.isDismissed = isDismissed
    }

    func shouldDisplay(persistedDecision: Bool) -> Bool {
        !isDismissed && persistedDecision
    }

    mutating func dismiss() {
        isDismissed = true
    }

    @discardableResult
    mutating func beginRetry() -> Bool {
        guard !isRetrying else { return false }
        isRetrying = true
        errorMessage = nil
        return true
    }

    mutating func finishRetry(errorMessage: String?) {
        isRetrying = false
        self.errorMessage = errorMessage
        if errorMessage == nil {
            isDismissed = false
            revision += 1
        }
    }
}
