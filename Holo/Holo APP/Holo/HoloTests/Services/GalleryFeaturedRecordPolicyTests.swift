//
//  GalleryFeaturedRecordPolicyTests.swift
//  HoloTests
//
//  日代表选择契约（方案 fixtures galleryCases C01–C09 逐条迁入）：
//  手选优先与回退、hero>legacy>text>other、同级时间倒序/键升序、去重计数、
//  partial/loaded/loadedEmpty 三态。
//

import XCTest
@testable import Holo

final class GalleryFeaturedRecordPolicyTests: XCTestCase {

    private func ev(_ key: String, _ kind: GalleryCandidateKind, order: Int,
                    deleted: Bool = false) -> GalleryCandidateEvent {
        GalleryCandidateEvent(key: key, kind: kind, occurredOrder: order,
                              visible: true, reliableTime: true, deleted: deleted)
    }

    func testC01EmptyDayLoadedEmpty() {
        let out = GalleryFeaturedRecordPolicy.select(events: [], loadComplete: true, manual: nil)
        XCTAssertEqual(out, .init(featured: nil, count: 0, state: .loadedEmpty))
    }

    func testC02HeroBeatsLegacyAndOther() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 1),
            ev("thought:b", .legacyPhoto, order: 9),
            ev("finance:c", .other, order: 10),
        ], loadComplete: true, manual: nil)
        XCTAssertEqual(out.featured, "thought:a")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.state, .loaded)
    }

    func testC03SameKindSameOrderKeyTieBreak() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 3),
            ev("thought:b", .hero, order: 3),
        ], loadComplete: true, manual: nil)
        XCTAssertEqual(out.featured, "thought:a")
        XCTAssertEqual(out.count, 2)
    }

    func testC04ManualActiveWins() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 3),
            ev("thought:b", .legacyPhoto, order: 1),
        ], loadComplete: true, manual: .init(key: "thought:b", availability: .active))
        XCTAssertEqual(out.featured, "thought:b")
        XCTAssertEqual(out.count, 2)
    }

    func testC05ManualPendingKeepsIdentityPartial() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 3),
        ], loadComplete: false, manual: .init(key: "thought:b", availability: .pending))
        XCTAssertEqual(out.featured, "thought:b", "手选元数据已到图片未同步：保持手选身份占位")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.state, .partial)
    }

    func testC06ManualDeletedFallsBackAndCountsDeleted() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 3),
            ev("thought:b", .hero, order: 8, deleted: true),
        ], loadComplete: true, manual: .init(key: "thought:b", availability: .deleted))
        XCTAssertEqual(out.featured, "thought:a", "手选记录确认已删：回退自动规则，保留手选版本")
        XCTAssertEqual(out.count, 2, "去重原事件数含已删除的历史事件")
    }

    func testC07DuplicateKeysDeduplicate() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .text, order: 2),
            ev("habit:b", .other, order: 9),
            ev("habit:b", .other, order: 9),
        ], loadComplete: true, manual: nil)
        XCTAssertEqual(out.featured, "thought:a")
        XCTAssertEqual(out.count, 2, "同一原记录多次聚合打卡去重")
    }

    func testC08ManualKeptWhenAssetDeleted() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .text, order: 1),
            ev("thought:b", .hero, order: 3),
        ], loadComplete: true, manual: .init(key: "thought:a", availability: .active))
        XCTAssertEqual(out.featured, "thought:a", "头图素材彻底删除但原记录仍在：保持手选（文字主预览）")
        XCTAssertEqual(out.count, 2)
    }

    func testC09PartialWhenLoadIncomplete() {
        let out = GalleryFeaturedRecordPolicy.select(events: [
            ev("thought:a", .hero, order: 3),
        ], loadComplete: false, manual: nil)
        XCTAssertEqual(out.featured, "thought:a")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.state, .partial)
    }

    func testDayKeyEncodesCalendarIdentity() {
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        cal.timeZone = tz
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9))!
        let key = GalleryFeaturedRecordPolicy.dayKey(for: date, calendar: cal, timeZone: tz)
        XCTAssertTrue(key.contains("gregorian"), key)
        XCTAssertTrue(key.contains("2026-11-17"), key)
        XCTAssertTrue(key.hasSuffix("Asia/Shanghai"), key)
        // 同一时刻不同时区 → 不同日键（切时区不误贴另一天）
        let ny = TimeZone(identifier: "America/New_York")!
        let keyNY = GalleryFeaturedRecordPolicy.dayKey(for: date, calendar: cal, timeZone: ny)
        XCTAssertNotEqual(key, keyNY)
    }
}
