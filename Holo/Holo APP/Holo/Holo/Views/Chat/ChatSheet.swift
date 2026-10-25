//
//  ChatSheet.swift
//  Holo
//
//  ChatView 的弹层路由枚举与轻量路由类型。
//  2026-10-23 从 ChatView.swift 拆出（红线 §6 行数减负第三次发作随案）：
//  类型与行为零变化，仅 private → internal 跨文件可见。
//

import SwiftUI

enum ChatSheet: Identifiable {
    case aiConsent
    #if DEBUG
    case aiSettings
    #endif
    /// 正式 HoloAI 用户设置页（2026-10-23「一个发现」统一设置：右上角齿轮 Debug/Release 都可见；
    /// 开发者 AI 调试页入口保留在该页 Debug 区，不再占用顶部齿轮）
    case holoAIUserSettings
    case editTransaction(Transaction)
    case analysisDetail(ChatMessageViewData)
    case voiceInput
    /// Matter「进行中的事」详情（内部路由，不占 Tab）
    case matterDetail(UUID)
    /// 方案卡已加入任务的详情（§8.1 单项「查看」）
    case taskDetail(UUID)
    // MARK: - 弹层收敛（2026-10-23 第四次发作二修）
    // 以下五个 case 原为 ChatView 散落的独立 sheet 修饰符 + 独立 @State：
    // 每层 sheet 修饰符都是 body 主链上的 AttributeGraph 节点（约 100KB 真机栈/层），
    // 五层散装弹层并入本枚举后 body 的 sheet 修饰符从 9 收敛到 4。
    case memoryConfirmationQueue
    /// 「Holo 记忆」管理页（2026-10-25 M08：聊天页右上角记忆入口）
    case memoryCenter
    case membershipCenter
    /// 待举报的 AI 消息（原 reportingMessage）
    case reportMessage(ChatMessageViewData)
    /// 待确认交易卡改分类（原 categoryEdit 三状态：message + itemID + prefill）
    case categoryEdit(message: ChatMessageViewData, itemID: String?, prefill: PendingTransactionPrefill)
    /// 待确认任务卡编辑会话（原 pendingTaskEdit）
    case taskEdit(PendingTaskEdit)

    var id: String {
        switch self {
        case .aiConsent:
            return "aiConsent"
        #if DEBUG
        case .aiSettings:
            return "aiSettings"
        #endif
        case .holoAIUserSettings:
            return "holoAIUserSettings"
        case .editTransaction(let transaction):
            return "editTransaction-\(transaction.id)"
        case .analysisDetail(let message):
            return "analysisDetail-\(message.id)"
        case .matterDetail(let id):
            return "matterDetail-\(id)"
        case .taskDetail(let id):
            return "taskDetail-\(id)"
        case .voiceInput:
            return "voiceInput"
        case .memoryConfirmationQueue:
            return "memoryConfirmationQueue"
        case .memoryCenter:
            return "memoryCenter"
        case .membershipCenter:
            return "membershipCenter"
        case .reportMessage(let message):
            return "reportMessage-\(message.id)"
        case .categoryEdit(let message, let itemID, _):
            return "categoryEdit-\(message.id)-\(itemID ?? "nil")"
        case .taskEdit(let edit):
            return "taskEdit-\(edit.messageID.uuidString)-\(edit.itemID)-\(edit.kind)"
        }
    }
}

/// 全屏 cover 通道路由（2026-10-23 弹层收敛）：窄屏全屏详情与财务证据搜索
/// 原为三个独立 fullScreenCover 修饰符，收敛为单通道单修饰符。
/// 宽屏（≥860）下 reportDetail / replayReader 走右侧栏（见 ChatView.activeSidePanel），
/// cover 通道在宽屏恒为 nil 不弹——门控逻辑在 ChatView 的映射 Binding。
enum ChatCoverRoute: Identifiable {
    case financeSearch(FlexibleQueryFinanceSearchRoute)
    case reportDetail(ChatMessageViewData)
    case replayReader(ChatMessageViewData)

    var id: String {
        switch self {
        case .financeSearch(let route):
            return "financeSearch-\(route.id)"
        case .reportDetail(let message):
            return "reportDetail-\(message.id)"
        case .replayReader(let message):
            return "replayReader-\(message.id)"
        }
    }
}

nonisolated struct FlexibleQueryFinanceSearchRoute: Identifiable {
    let id = UUID()
    let keyword: String?
    let transactionIDs: [UUID]

    init?(cardData: FlexibleQueryChatCardData) {
        guard !cardData.resultTransactionIDs.isEmpty else { return nil }
        keyword = cardData.searchKeyword
        transactionIDs = cardData.resultTransactionIDs
    }
}

/// 待删除卡片的信息（用于确认弹窗）
struct PendingCardDelete {
    let category: EntityCategory
    let entityId: UUID
    let description: String
}
