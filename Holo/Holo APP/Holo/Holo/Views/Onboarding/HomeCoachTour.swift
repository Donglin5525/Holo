//
//  HomeCoachTour.swift
//  Holo
//
//  首页三步聚光灯导览：V1 轻量引导结束后立即播放，教新用户看懂首页地图。
//  顺序讲故事：记录（五角形入口）→ 查看（今日看板）→ 对话与回顾（AI + 记忆长廊）。
//

import Foundation

enum HomeCoachTour {

    /// 与 HomeView 内 .coachMarkTarget(id) 挂点一一对应
    static let featureButtonsID = "home.featureButtons"
    static let kanbanEntryID = "home.kanbanEntry"
    static let bottomNavID = "home.bottomNav"

    static var steps: [CoachMarkStep] {
        [
            CoachMarkStep(
                targetID: featureButtonsID,
                title: "生活的五个入口",
                message: "任务、财务、习惯、健康、想法，点开就能记录。长按图标还可以拖动，把最常用的放到顺手的位置。"
            ),
            CoachMarkStep(
                targetID: kanbanEntryID,
                title: "今天，一目了然",
                message: "点开看今天的任务、习惯和健康全貌，Holo 每天在这里帮你收个尾。"
            ),
            CoachMarkStep(
                targetID: bottomNavID,
                title: "随时找 Holo 聊聊",
                message: "不用想“该去哪记”——直接告诉 Holo 一件事，比如“午饭花了 35 元”，它会帮你记好。右边是记忆长廊，你的记录会自动汇成那里。",
                // 底部导航的中央 AI 按钮用 offset 凸出导航条布局 frame，
                // 洞必须外扩更多才能把凸起完整含进去，否则按钮顶部被遮罩切掉
                padding: 40
            ),
        ]
    }
}

// MARK: - 设置页「重看新手引导」信号

extension Notification.Name {
    /// 设置页触发首页导览重播（HomeView 收到后先退回首页再播放）
    static let replayHomeCoachTour = Notification.Name("com.holo.replayHomeCoachTour")
}
