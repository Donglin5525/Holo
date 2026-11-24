//
//  TaskListEmptyState.swift
//  Holo
//
//  任务列表 V1 的空态（2026-11-23 审美七项 P5）：一句话留白，不放图标与胶囊按钮。
//  今天分支安静收尾、无动作；其余分支给出「写第一件事」入口（无回调时退为纯留白）。
//  「正在从 iCloud 恢复数据……」提示保留在组件下方。
//

import SwiftUI

/// V1 任务列表空态（TaskListView 专用，从列表文件拆出守住行数闸门）
struct TaskListEmptyState: View {
    /// 「今天」筛选分支（无动作，只留白）
    let isTodayScope: Bool
    /// 新建任务回调（nil = 不显示动作链接）
    let onAddRequested: (() -> Void)?
    /// 首次 iCloud 同步未完成时显示恢复提示
    let showsRestoreHint: Bool

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if isTodayScope {
                HoloQuietEmptyState(
                    line: "今天没什么非做不可的事。",
                    byline: "— 好好过"
                )
            } else if let onAddRequested {
                HoloQuietEmptyState(
                    line: "今天还是\n一张白纸。",
                    byline: "— 想做点什么，就写下来",
                    actionTitle: "写第一件事",
                    actionStyle: .accent,
                    action: onAddRequested,
                    actionIdentifier: "taskEmptyCta"
                )
            } else {
                HoloQuietEmptyState(
                    line: "今天还是\n一张白纸。",
                    byline: "— 想做点什么，就写下来"
                )
            }

            if !isTodayScope, showsRestoreHint {
                Text("正在从 iCloud 恢复数据，稍等片刻就会显示")
                    .font(.holoCaption)
                    .foregroundColor(.holoInfo)
                    .transition(.opacity)
            }
        }
    }
}
