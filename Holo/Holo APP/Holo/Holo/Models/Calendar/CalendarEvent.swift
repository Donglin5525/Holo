//
//  CalendarEvent.swift
//  Holo
//
//  日历视图统一事件模型（单条，1:1 对应一条原始记录）
//

import Foundation
import CoreData

/// 日历视图的单条事件（一条记账 / 一条习惯打卡 / 一条待办 / 一条想法）
///
/// 设计为单条 1:1 实体（非聚合）：月历的色阶/色条由渲染层从 [CalendarEvent] 计算。
/// 不复用 MemoryItem——它是去模块化的展示 struct，丢失了模块身份与原始实体引用。
struct CalendarEvent: Identifiable, Equatable {
    let id: UUID
    let module: CalendarModule

    /// 带时刻，时间轴定位锚点
    let date: Date

    /// 列表/详情主标题
    let title: String

    /// 金额 / 数值 / 摘要等副信息
    let detail: String?

    /// 分类、账户、备注等辅助语境；不与主标题争夺视觉层级
    let context: String?

    /// 可聚合的原始数值（日回放把同一分钟的多笔记账合成一个「记忆时刻」）
    let numericValue: Decimal?

    /// 数值方向：收入为正、支出为负；非记账事件不设置
    let valueDirection: CalendarEventValueDirection?

    /// P3：相关观点标题（仅想法模块，经 Thought.topics 间接体现观点维度）
    let relatedTopics: [String]?

    /// 附件缩略图数据（仅想法模块；册页风照片堆直接消费，最大 9 张 300×300）
    let attachmentThumbnails: [Data]

    /// 原始实体对象 ID（跨线程安全，用于「在 X 模块打开」回查实体；UI 不直接消费）
    let originID: NSManagedObjectID

    init(id: UUID = UUID(),
         module: CalendarModule,
         date: Date,
         title: String,
         detail: String? = nil,
         context: String? = nil,
         numericValue: Decimal? = nil,
         valueDirection: CalendarEventValueDirection? = nil,
         relatedTopics: [String]? = nil,
         attachmentThumbnails: [Data] = [],
         originID: NSManagedObjectID) {
        self.id = id
        self.module = module
        self.date = date
        self.title = title
        self.detail = detail
        self.context = context
        self.numericValue = numericValue
        self.valueDirection = valueDirection
        self.relatedTopics = relatedTopics
        self.attachmentThumbnails = attachmentThumbnails
        self.originID = originID
    }

    /// 按 id 判等（同一条原始记录即同一事件）
    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id
    }
}

enum CalendarEventValueDirection: Hashable {
    case positive
    case negative
}

extension CalendarEvent {

    /// 数据源只能确定日期（时间部分为 0 点整）时视为无可靠时刻。
    /// 补签、账单导入等场景落 0 点的记录归入日回放「当天记录」区，
    /// 不伪装成凌晨事件（统一浏览方案 §7.6 / §15.2：不制造虚假时间精度）。
    var hasReliableTime: Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return !(comps.hour == 0 && comps.minute == 0 && comps.second == 0)
    }
}
