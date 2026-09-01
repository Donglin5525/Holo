//
//  EmojiCatalogSearchTests.swift
//  HoloTests
//
//  emoji 搜索排序与口语补充词测试
//

import XCTest
@testable import Holo

final class EmojiCatalogSearchTests: XCTestCase {

    // MARK: - 排序：短关键词优先

    func testSearchCarRanksAutomobileFirst() {
        let results = EmojiCatalog.search(matching: "车")
        // 🚗 补充了单字「车」（距离最短），必须置顶；此前按目录顺序它排第 33 位
        XCTAssertEqual(results.first, "🚗")
        // 皮卡 🛻 的生成索引里也有单字「车」，紧随其后
        XCTAssertTrue(results.dropFirst().prefix(3).contains("🛻"))
    }

    func testShorterKeywordOutranksLongerCompound() {
        let results = EmojiCatalog.search(matching: "车")
        // 「汽车」(2字) 的 🚗 应排在「骑车」(2字但目录靠后) 与「过山车」(3字) 之前
        let carIndex = results.firstIndex(of: "🚗")!
        let bikeIndex = results.firstIndex(of: "🚴")!
        let rollerCoasterIndex = results.firstIndex(of: "🎢")!
        XCTAssertLessThan(carIndex, bikeIndex)
        XCTAssertLessThan(carIndex, rollerCoasterIndex)
    }

    func testSupplementKeywordOutranksGeneratedOfSameLength() {
        let results = EmojiCatalog.search(matching: "汽车")
        // 生成索引给警车 🚓 也标了「汽车」，人工补充层的 🚗 应在同长度时优先
        XCTAssertEqual(results.first, "🚗")
        XCTAssertTrue(results.contains("🚓"))
    }

    // MARK: - 口语补充词

    func testColloquialTransportWords() {
        XCTAssertEqual(EmojiCatalog.search(matching: "打车").first, "🚕")
        XCTAssertEqual(EmojiCatalog.search(matching: "交通").first, "🚗")
        XCTAssertEqual(EmojiCatalog.search(matching: "出行").first, "🚗")
        XCTAssertFalse(EmojiCatalog.search(matching: "代步").isEmpty)
    }

    func testColloquialFinanceSceneWords() {
        XCTAssertEqual(EmojiCatalog.search(matching: "买菜").first, "🥬")
        XCTAssertEqual(EmojiCatalog.search(matching: "房租").first, "🏠")
        XCTAssertEqual(EmojiCatalog.search(matching: "工资").first, "💰")
        XCTAssertEqual(EmojiCatalog.search(matching: "通勤").first, "💼")
        XCTAssertEqual(EmojiCatalog.search(matching: "旅游").first, "🧳")
    }

    func testEnglishShortWords() {
        XCTAssertEqual(EmojiCatalog.search(matching: "car").first, "🚗")
        XCTAssertEqual(EmojiCatalog.search(matching: "bike").first, "🚲")
    }

    // MARK: - 基础行为不回归

    func testGeneratedIndexStillWorks() {
        // 生成索引里的原有关键词不受补充层影响
        XCTAssertEqual(EmojiCatalog.search(matching: "汽车").count, 15)
        XCTAssertEqual(EmojiCatalog.search(matching: "火车").first, "🚂")
        XCTAssertEqual(EmojiCatalog.search(matching: "轿车").first, "🚗")
    }

    func testBlankQueryReturnsEmpty() {
        XCTAssertTrue(EmojiCatalog.search(matching: "  ").isEmpty)
        XCTAssertTrue(EmojiCatalog.search(matching: "").isEmpty)
    }
}
