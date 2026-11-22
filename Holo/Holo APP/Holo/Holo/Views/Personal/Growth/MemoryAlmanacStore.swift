//
//  MemoryAlmanacStore.swift
//  Holo
//
//  「我的积累 · 人生年鉴」数据加载（2026-11-22 从记忆长廊洞察页迁来）。
//  init 零 I/O；后台 context 查询按天件数（MemoryDayCountQuery 唯一口径），主线程组装纯值模型。
//

import Combine
import Foundation
import os

@MainActor
final class MemoryAlmanacStore: ObservableObject {
    @Published private(set) var almanac: MemoryAlmanacYear?
    /// 开始记录日：翻年下限与新用户副行
    @Published private(set) var firstRecordDate: Date?

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryAlmanac")

    /// 可翻到的最早年份（开始记录那年；从未记录时为今年）
    var earliestYear: Int {
        Calendar.current.component(.year, from: firstRecordDate ?? Date())
    }

    /// 加载指定年份；不传则刷新当前展示的年份（首次为今年）
    func load(year: Int? = nil) async {
        let target = year ?? almanac?.year ?? Calendar.current.component(.year, from: Date())
        do {
            let (counts, firstRecord) = try await CoreDataStack.shared.performBackgroundTask { context in
                (MemoryDayCountQuery.dayCounts(year: target, context: context),
                 MemoryDayCountQuery.firstRecordDate(context: context))
            }
            firstRecordDate = firstRecord
            almanac = MemoryAlmanacBuilder.build(year: target, dayCounts: counts, today: Date(), firstRecordDate: firstRecord)
        } catch {
            Self.logger.error("年鉴加载失败 year=\(target, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
