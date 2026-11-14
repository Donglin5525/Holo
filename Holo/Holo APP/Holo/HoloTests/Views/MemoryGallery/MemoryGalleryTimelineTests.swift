//
//  MemoryGalleryTimelineTests.swift
//  HoloTests
//
//  长廊时间线主预览选取（暖光规格 §2「长廊默认页」）：
//  - 优先级：带附件想法 > 可读正文想法 > 最近一条有可靠时刻的记录 > 稳定身份兜底
//  - 其余记录：可靠时刻从晚到早，无可靠时刻置末
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class MemoryGalleryTimelineTests: XCTestCase {

    private var objectID: NSManagedObjectID {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        let thought = context.insertTestObject(Thought.self)
        thought.id = UUID()
        thought.content = "占位"
        try? context.save()
        return thought.objectID
    }

    private func event(_ module: CalendarModule, hour: Int, title: String,
                       attachments: Int = 0) -> CalendarEvent {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 21
        c.hour = hour == 0 ? 0 : hour
        return CalendarEvent(module: module,
                             date: Calendar.current.date(from: c) ?? Date(),
                             title: title,
                             attachmentThumbnails: attachments > 0 ? [Data([1])] : [],
                             originID: objectID)
    }

    func test_带附件想法优先做主预览() {
        let readable = event(.thought, hour: 20, title: "薄荷换盆后，闻起来满手都是薄荷味。")
        let withImage = event(.thought, hour: 18, title: "窗台的薄荷", attachments: 1)
        let split = MemoryGalleryDayPreview.split([readable, withImage])
        XCTAssertEqual(split.featured?.id, withImage.id)
        XCTAssertEqual(split.others.map(\.id), [readable.id])
    }

    func test_可读正文想法胜过有时刻记录() {
        let thought = event(.thought, hour: 8, title: "清晨想到的一件事，值得记下来。")
        let latestRecord = event(.finance, hour: 22, title: "晚饭")
        let split = MemoryGalleryDayPreview.split([latestRecord, thought])
        XCTAssertEqual(split.featured?.id, thought.id)
    }

    func test_无想法时取最近一条有时刻记录() {
        let early = event(.habit, hour: 9, title: "晨跑")
        let late = event(.finance, hour: 21, title: "打车")
        let split = MemoryGalleryDayPreview.split([early, late])
        XCTAssertEqual(split.featured?.id, late.id, "最近一条有时刻记录做主预览")
        XCTAssertEqual(split.others.map(\.id), [early.id])
    }

    func test_其余记录从晚到早无可靠时刻置末() {
        let a = event(.habit, hour: 9, title: "早")
        let b = event(.finance, hour: 20, title: "晚")
        let featured = event(.thought, hour: 12, title: "想法，正文可读。")
        let untimed = CalendarEvent(module: .todo, date: {
            var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 21
            return Calendar.current.date(from: c) ?? Date()
        }(), title: "无时刻任务", originID: objectID)
        let split = MemoryGalleryDayPreview.split([a, b, featured, untimed])
        XCTAssertEqual(split.featured?.id, featured.id)
        XCTAssertEqual(split.others.map(\.id), [b.id, a.id, untimed.id], "从晚到早，无时刻置末")
    }

    func test_全部无时刻时按稳定身份兜底() {
        let untimed1 = CalendarEvent(module: .habit, date: Date(timeIntervalSince1970: 1_700_000_000),
                                     title: "打卡", originID: objectID)
        let untimed2 = CalendarEvent(module: .finance, date: Date(timeIntervalSince1970: 1_700_000_000),
                                     title: "账单", originID: objectID)
        let split = MemoryGalleryDayPreview.split([untimed1, untimed2])
        XCTAssertNotNil(split.featured)
        XCTAssertEqual(split.others.count, 1)
    }
}
