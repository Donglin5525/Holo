//
//  ReceiptBookingPagePresenter.swift
//  Holo
//
//  识图记账落点页的置顶呈现状态（2026-11-24）。App 根视图订阅它弹出；深链处理器只负责请求。
//
//  此前确认页挂在 FinanceView 上，靠「先收掉挡路弹层 + 等 dismissal 落定再弹」保证到达，
//  补丁认不全所有页面（聊天页等兄弟模块的 sheet 就收不到）——东林实报「开着别的页面，
//  截图记账的内容要关掉那个页面才出来」。现在由置顶弹层直接盖在最上面，底下的页面不动，
//  处理完回到原处。
//

import Combine
import Foundation

/// 识图记账深链的落点页（App 根视图置顶弹层的 item）
enum ReceiptBookingPage: Hashable, Identifiable {
    /// 待复核直达（完整方案 §25.3）
    case review(draftID: UUID)
    /// 最近结果 → 识图记账设置页
    case bookingSettings(resultID: UUID)

    var id: Self { self }
}

@MainActor
final class ReceiptBookingPagePresenter: ObservableObject {
    static let shared = ReceiptBookingPagePresenter()

    @Published private(set) var page: ReceiptBookingPage?

    private init() {}

    /// 同一页已开着时不动：重派深链、重复点同一条兜底通知都不重弹
    func present(_ target: ReceiptBookingPage) {
        if page == target { return }
        page = target
    }

    func dismiss() {
        page = nil
    }
}
