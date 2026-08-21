//
//  ChatReportTabRouter.swift
//  Holo
//
//  「报告」Tab 的跨模块跳转入口
//  聊天流分析卡的「已存入报告」回执、记忆长廊洞察 Tab 的报告门卡，
//  都通过它请求 ChatView 切到报告 Tab——参照长廊 consumeMemoryFocus 的
//  pending-target 消费模式：请求方只发信号，由常驻的 ChatView 消费。
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatReportTabRouter: ObservableObject {
    static let shared = ChatReportTabRouter()

    /// 每次请求自增；ChatView 通过 onReceive 消费并切换 Tab。
    /// ChatView 尚未创建时（首启）由其 .task 里的 consumePendingRequest() 补消费。
    @Published private(set) var requestTicket: Int = 0

    /// 是否存在尚未被 ChatView 消费的请求（供首启补消费判断）。
    private(set) var hasPendingRequest = false

    func openReportTab() {
        hasPendingRequest = true
        requestTicket += 1
    }

    /// 仅在 ChatView 首次进入时调用：把冷启动前发出的请求消费掉。
    func consumePendingRequest() -> Bool {
        defer { hasPendingRequest = false }
        return hasPendingRequest
    }
}
