//
//  MemoryGalleryDayRequest.swift
//  Holo
//
//  跨页面「在长廊里看这一天」的待定位日期（2026-11-22，人生年鉴移到「我的积累」）。
//  发起方写入日期后用既有 `.memoryGallery` 深链打开长廊；长廊出现或收到变化时消费，
//  交给 MemoryGalleryFindDateModel.requestJump 定位时间线（与「找日期」同一条路径）。
//  不新增 DeepLinkTarget 分支，避免改动各处穷举 switch。
//

import Combine
import Foundation

@MainActor
final class MemoryGalleryDayRequest: ObservableObject {
    static let shared = MemoryGalleryDayRequest()

    /// 待定位的日期（当天零点）；长廊消费后置空
    @Published var pendingDay: Date?

    private init() {}

    func request(_ day: Date) {
        pendingDay = Calendar.current.startOfDay(for: day)
    }

    /// 取出并清空待定位日期
    func consume() -> Date? {
        defer { pendingDay = nil }
        return pendingDay
    }
}
