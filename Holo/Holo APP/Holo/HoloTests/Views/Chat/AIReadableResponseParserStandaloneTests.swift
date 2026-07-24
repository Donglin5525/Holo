//
//  AIReadableResponseParserStandaloneTests.swift
//  HoloTests
//
//  通用 AI 阅读排版解析器独立测试，不依赖 App 测试宿主。
//

import Foundation

@discardableResult
private func expectReadableResponse(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    guard condition() else {
        fatalError(message)
    }
    return true
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        AIReadableResponseParserStandaloneTests.main()
    }
}
#endif
enum AIReadableResponseParserStandaloneTests {

    static func main() {
        test自然文本形成首段与小标题()
        testMarkdown标题与列表保留结构()
        test详细分析进入折叠区()
        test单句回答保持普通段落()
        test卡片标记不会泄漏到正文()
        print("AIReadableResponseParserStandaloneTests passed")
    }

    private static func test自然文本形成首段与小标题() {
        let document = AIReadableResponseParser.parse(
            """
            先别急着把它归结为自律不足。

            如果拖延主要发生在 Holo 开发上，更可能是任务太大、反馈太慢，让你很难获得明确的完成感。

            可以先做一件事
            从今天的任务里，只选一个能够在 30 分钟内彻底结束的小步骤。先完成，再决定是否继续。
            """
        )

        expectReadableResponse(document.blocks.count == 4, "自然文本应解析为首段、正文、小标题和正文")
        expectReadableResponse(document.blocks[0] == .lead("先别急着把它归结为自律不足。"), "第一段短结论应成为 lead")
        expectReadableResponse(document.blocks[1] == .paragraph("如果拖延主要发生在 Holo 开发上，更可能是任务太大、反馈太慢，让你很难获得明确的完成感。"), "解释段应保持正文")
        expectReadableResponse(document.blocks[2] == .heading("可以先做一件事"), "自然短标题应被识别")
        expectReadableResponse(document.blocks[3] == .paragraph("从今天的任务里，只选一个能够在 30 分钟内彻底结束的小步骤。先完成，再决定是否继续。"), "行动段应保持正文")
        expectReadableResponse(document.detailBlocks.isEmpty, "普通回答不应被自动折叠")
    }

    private static func testMarkdown标题与列表保留结构() {
        let document = AIReadableResponseParser.parse(
            """
            ## 可以先试试

            - 把任务缩小
            - 只保留一个结束标准

            1. 先做十分钟
            2. 再决定是否继续
            """
        )

        expectReadableResponse(document.blocks == [
            .heading("可以先试试"),
            .unorderedList(["把任务缩小", "只保留一个结束标准"]),
            .orderedList(["先做十分钟", "再决定是否继续"])
        ], "Markdown 块结构不应被压平成一个 Text")
    }

    private static func test详细分析进入折叠区() {
        let document = AIReadableResponseParser.parse(
            """
            先把今天最重要的一件事做完。

            详细分析
            任务范围过大时，开始成本会明显升高。

            - 反馈周期太长
            - 完成标准不清楚
            """
        )

        expectReadableResponse(document.blocks == [.lead("先把今天最重要的一件事做完。")], "核心回答必须留在首屏")
        expectReadableResponse(document.detailBlocks == [
            .paragraph("任务范围过大时，开始成本会明显升高。"),
            .unorderedList(["反馈周期太长", "完成标准不清楚"])
        ], "详细分析后的内容应进入折叠区")
    }

    private static func test单句回答保持普通段落() {
        let document = AIReadableResponseParser.parse("好的，我帮你一起看看。")
        expectReadableResponse(document.blocks == [.paragraph("好的，我帮你一起看看。")], "单句短回答不应被过度强调")
    }

    private static func test卡片标记不会泄漏到正文() {
        let document = AIReadableResponseParser.parse(
            """
            本周支出比上周更集中。

            {{card:summary}}

            建议先核对两笔大额记录。
            """
        )

        expectReadableResponse(document.blocks == [
            .lead("本周支出比上周更集中。"),
            .paragraph("建议先核对两笔大额记录。")
        ], "卡片标记应被忽略，同时保留其余文字")
    }
}
