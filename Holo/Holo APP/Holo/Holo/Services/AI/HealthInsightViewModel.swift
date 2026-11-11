//
//  HealthInsightViewModel.swift
//  Holo
//
//  健康洞察 UI 状态（2026-11-09 后台隐性生成改造）：
//  页面只读缓存——打开立即显示缓存/保底文案，生成由 HealthInsightScheduler
//  在后台单飞行完成，页面通过 @Observable 转发实时更新，离开页面不取消生成。
//

import SwiftUI

@MainActor
@Observable
final class HealthInsightViewModel {

    private let scheduler: HealthInsightScheduler

    /// 页面显示快照：转发单飞行生成器的 @Observable 状态，生成完成即实时更新。
    var snapshot: GeneratedHealthInsightSnapshot? { scheduler.snapshot }

    init(scheduler: HealthInsightScheduler? = nil) {
        self.scheduler = scheduler ?? .shared
    }

    /// 页面打开：播种只读显示快照 + 发起后台按需生成（不等待，离开页面不取消）。
    func load() {
        scheduler.seedSnapshotForDisplay()
        scheduler.recordHealthPageVisit()
        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
    }

    /// 手动刷新：每天 3 次上限（cache 层），绕过新鲜度规则，走单飞行生成器。
    func refresh() {
        scheduler.refreshManually()
    }

    /// 手动刷新是否可用（UI 按钮禁用判断）。
    func canRefresh() -> Bool {
        scheduler.canRefreshManually()
    }
}
