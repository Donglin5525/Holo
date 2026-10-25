//
//  DiscoveryQuoteAlignmentTests.swift
//  HoloTests
//
//  「一个发现」G2 引用对齐测试（02 §2.3；04 验收矩阵 T24/T42 口径）：
//  精确子串原样 / 仅排版差异→原文精确子串 / 改写拒绝三态；
//  emoji 代理对、繁简、CRLF、重复 quote 消歧（不许取第一个）。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
@testable import Holo

final class DiscoveryQuoteAlignmentTests: XCTestCase {

    // MARK: - 三态基础

    func test_精确子串_原样返回() {
        let source = "停了一阵，今天先出去走了十分钟。没有要求自己一定跑起来。"
        let outcome = DiscoveryQuoteAlignment.align(quote: "今天先出去走了十分钟", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "今天先出去走了十分钟")
        XCTAssertEqual(source.dropFirst(outcome!.sourceUTF16Range.lowerBound).prefix(10), "今天先出去走了十分钟")
    }

    func test_改写拒绝_换词与加词都不对齐() {
        let source = "停了一阵，今天先出去走了十分钟。没有要求自己一定跑起来。"
        // 换词（改写）
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "今天出门跑步十分钟", source: source))
        // 加词（改写；「自己」不在原文该处）
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "没有要求自己一定每天都跑起来", source: source))
        // 删词（改写）：原文含「自己」，quote 删掉它即非子串
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "要求一定跑起来", source: "没有要求自己一定跑起来，后来停了"))
        // 注：quote 是原文连续子串时（哪怕语义上截掉了句首否定）对齐本就通过——
        // 「截走否定」由核验阶段整段上下文拦截（02 §2.3 第 4 条），不是对齐的职责。
        XCTAssertNotNil(DiscoveryQuoteAlignment.align(quote: "一定跑起来", source: "没有要求自己一定跑起来，后来停了"))
    }

    func test_否定保留_整句精确对齐不改写文本() {
        let source = "重新读书，今晚只翻了两页，没有要求读完一章。"
        let outcome = DiscoveryQuoteAlignment.align(quote: "没有要求读完一章", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "没有要求读完一章", "对齐结果必须逐字保留否定")
    }

    // MARK: - 排版差异（T24）

    func test_排版差异_全角空格与弯引号_回精确原文() {
        let source = "今天　先出去走了“十分钟”，感觉可以。"
        // quote：半角空格 + 直引号（仅排版不同）
        let outcome = DiscoveryQuoteAlignment.align(quote: "今天 先出去走了\"十分钟\"", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "今天　先出去走了“十分钟”", "必须回原文精确子串（含全角空格与弯引号）")
    }

    func test_排版差异_CRLF与多空白() {
        let source = "走路十分钟。\r\n\r\n还是没有继续。"
        let outcome = DiscoveryQuoteAlignment.align(quote: "走路十分钟。还是没有继续。", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "走路十分钟。\r\n\r\n还是没有继续。", "slice 连续区间包住中间空白")
    }

    func test_排版差异_大小写统一() {
        let source = "Finished the Portfolio Cover."
        let outcome = DiscoveryQuoteAlignment.align(quote: "finished the portfolio cover", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "Finished the Portfolio Cover")
    }

    func test_中文引号折叠() {
        let source = "备注『只翻两页』就好。"
        let outcome = DiscoveryQuoteAlignment.align(quote: "备注\"只翻两页\"就好", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "备注『只翻两页』就好")
    }

    // MARK: - Unicode / emoji / 繁简（T42）

    func test_emoji_代理对与ZWJ序列不切断() {
        let source = "走了 10 分钟 🏃‍♀️ 感觉不错，明天继续。"
        let outcome = DiscoveryQuoteAlignment.align(quote: "走了10分钟🏃‍♀️感觉不错", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "走了 10 分钟 🏃‍♀️ 感觉不错")
        // 原文按返回范围切片必须能还原同一字符串（不切在代理对中间）。
        // 必须按 UTF-16 索引切片——dropFirst/prefix 是 Character 口径，拿 UTF-16 数量
        // 去喂会多吃字符（ZWJ 序列 5 个码元只算 1 个 Character）。
        let range = outcome!.sourceUTF16Range
        let view = source.utf16
        let start = view.index(view.startIndex, offsetBy: range.lowerBound)
        let end = view.index(start, offsetBy: range.count)
        let sliced = String(decoding: view[start..<end], as: UTF16.self)
        XCTAssertEqual(sliced, "走了 10 分钟 🏃‍♀️ 感觉不错")
    }

    func test_繁简不做模糊匹配() {
        let source = "今天走了十分钟。"   // 简体
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "今天走了十分鐘", source: source), "繁简差异=内容差异，拒绝（无模糊相似度）")
        // 同为繁体可精确对齐
        let traditional = "今天走了十分鐘。"
        XCTAssertEqual(DiscoveryQuoteAlignment.align(quote: "走了十分鐘", source: traditional)?.exactSubstring, "走了十分鐘")
    }

    func test_长原文_对齐不越界() {
        let paragraph = String(repeating: "这一段是凑字数的正文内容，与引用无关。", count: 40)
        let source = paragraph + "今晚只翻了两页，没有要求读完一章。" + paragraph
        let outcome = DiscoveryQuoteAlignment.align(quote: "今晚只翻了两页，没有要求读完一章。", source: source)
        XCTAssertEqual(outcome?.exactSubstring, "今晚只翻了两页，没有要求读完一章。")
        XCTAssertTrue(outcome!.sourceUTF16Range.upperBound <= source.utf16.count, "范围不越界")
    }

    // MARK: - 重复 quote 消歧（不许取第一个）

    func test_重复quote_精确路径_无块提示拒绝() {
        let source = "上午先写提纲。中间隔了很多无关内容，略。晚上又先写提纲。"
        XCTAssertNil(
            DiscoveryQuoteAlignment.align(quote: "先写提纲", source: source),
            "精确子串多次命中且无 sourceBlock 范围 → 拒绝，不取第一个"
        )
    }

    func test_重复quote_精确路径_块提示唯一定位() {
        let source = "上午先写提纲。中间隔了很多无关内容，略。晚上又先写提纲。"
        // 第二处「先写提纲」的原文范围：手工计算（「晚上又」之后）
        let marker = "晚上又"
        let markerStart = source.distance(from: source.startIndex, to: source.range(of: marker)!.lowerBound)
        let secondStartUTF16 = source.prefix(markerStart + marker.count).utf16.count
        let blockRange = secondStartUTF16..<(secondStartUTF16 + "先写提纲".utf16.count)

        let outcome = DiscoveryQuoteAlignment.align(quote: "先写提纲", source: source, sourceBlockUTF16Range: blockRange)
        XCTAssertEqual(outcome?.exactSubstring, "先写提纲")
        XCTAssertEqual(outcome?.sourceUTF16Range, blockRange, "必须定位到块内第二处，不是第一处")
    }

    func test_重复quote_排版路径_无提示拒绝_有提示回正确原文() {
        let source = "先写 提纲。隔段。先写\t提纲。"
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "先写提纲", source: source), "两处排版命中无法区分 → 拒绝")

        // 第二处含 \t：给覆盖第二处的块范围
        let marker = "隔段。"
        let markerEnd = source.distance(from: source.startIndex, to: source.range(of: marker)!.upperBound)
        let blockStartUTF16 = source.prefix(markerEnd).utf16.count
        let blockRange = blockStartUTF16..<source.utf16.count

        let outcome = DiscoveryQuoteAlignment.align(quote: "先写提纲", source: source, sourceBlockUTF16Range: blockRange)
        XCTAssertEqual(outcome?.exactSubstring, "先写\t提纲", "回块内原文精确子串（含制表符），不是第一处")
    }

    func test_重复quote_块范围覆盖两处仍拒绝() {
        let source = "先写 提纲。先写\t提纲。"
        XCTAssertNil(
            DiscoveryQuoteAlignment.align(quote: "先写提纲", source: source, sourceBlockUTF16Range: 0..<source.utf16.count),
            "块范围包住两处命中，仍无法区分 → 拒绝"
        )
    }

    // MARK: - 边界

    func test_空quote与纯空白quote拒绝() {
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "", source: "正文"))
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: " 　\n\t", source: "正文"), "归一化后为空 → 拒绝（JS 同口径）")
    }

    func test_quote长于原文拒绝() {
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "很长的引用内容比原文还长", source: "短文"))
    }

    func test_空原文拒绝() {
        XCTAssertNil(DiscoveryQuoteAlignment.align(quote: "任何", source: ""))
    }
}
