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
        test规范表格解析为表格块()
        test缺分隔行的连续竖线行兜底为表格()
        test表格夹在段落与列表之间()
        test详细分析折叠区内表格()
        test单行竖线不算表格()
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

    private static func test规范表格解析为表格块() {
        let document = AIReadableResponseParser.parse(
            """
            这是本周的支出对比：

            | 分类 | 本周 | 上周 |
            | --- | --- | --- |
            | 餐饮 | 328 元 | 410 元 |
            | 交通 | 96 元 | 88 元 |
            """
        )

        expectReadableResponse(document.blocks.count == 2, "表格前段落应独立成块")
        expectReadableResponse(document.blocks[0] == .lead("这是本周的支出对比："), "表格前短引导句按既有规则升级为 lead")
        expectReadableResponse(document.blocks[1] == .table(
            header: ["分类", "本周", "上周"],
            rows: [["餐饮", "328 元", "410 元"], ["交通", "96 元", "88 元"]]
        ), "标准 GFM 表格应解析为表格块且单元格去除竖线与空白")
    }

    private static func test缺分隔行的连续竖线行兜底为表格() {
        let document = AIReadableResponseParser.parse(
            """
            | 分类 | 金额 |
            | 餐饮 | 328 元 |
            | 交通 | 96 元 |
            """
        )

        expectReadableResponse(document.blocks == [
            .table(header: ["分类", "金额"], rows: [["餐饮", "328 元"], ["交通", "96 元"]])
        ], "缺分隔行但连续竖线行应兜底按表格处理，首行当表头")
    }

    private static func test表格夹在段落与列表之间() {
        let document = AIReadableResponseParser.parse(
            """
            | 项目 | 状态 |
            | --- | --- |
            | 交房租 | 已完成 |

            接下来可以：

            - 核对水电费
            - 记录本周总结
            """
        )

        expectReadableResponse(document.blocks.count == 3, "表格前后内容应独立成块")
        expectReadableResponse(document.blocks[0] == .table(header: ["项目", "状态"], rows: [["交房租", "已完成"]]), "表格应完整解析")
        expectReadableResponse(document.blocks[1] == .paragraph("接下来可以："), "表格后的段落应正常衔接")
        expectReadableResponse(document.blocks[2] == .unorderedList(["核对水电费", "记录本周总结"]), "表格后的列表应正常收集")
    }

    private static func test详细分析折叠区内表格() {
        let document = AIReadableResponseParser.parse(
            """
            餐饮支出在回落。

            详细分析
            | 周 | 金额 |
            | --- | --- |
            | 第 1 周 | 410 元 |
            | 第 2 周 | 328 元 |
            """
        )

        expectReadableResponse(document.blocks == [.lead("餐饮支出在回落。")], "核心回答必须留在首屏")
        expectReadableResponse(document.detailBlocks == [
            .table(header: ["周", "金额"], rows: [["第 1 周", "410 元"], ["第 2 周", "328 元"]])
        ], "详细分析内的表格应进入折叠区")
    }

    private static func test单行竖线不算表格() {
        let document = AIReadableResponseParser.parse("备注 | 金额 | 日期")
        expectReadableResponse(document.blocks == [.paragraph("备注 | 金额 | 日期")], "孤立竖线行应保持普通段落，不误判表格")
    }
}
