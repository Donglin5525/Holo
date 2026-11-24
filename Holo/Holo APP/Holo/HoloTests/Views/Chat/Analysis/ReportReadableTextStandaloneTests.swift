//
//  ReportReadableTextStandaloneTests.swift
//  HoloTests
//
//  深度报告可读性文本工具独立测试（不依赖 App 测试宿主）。
//  运行：swiftc -parse-as-library Holo/Views/Chat/Analysis/ReportReadableText.swift \
//        HoloTests/Views/Chat/Analysis/ReportReadableTextStandaloneTests.swift -o /tmp/rrt && /tmp/rrt
//

import Foundation

@discardableResult
private func expectReportReadable(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        #if HOLO_XCTEST_BRIDGE
        XCTFail(message)
        #else
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
        #endif
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
        ReportReadableTextStandaloneTests.main()
        FileHandle.standardOutput.write(Data("ReportReadableText: all passed\n".utf8))
    }
}
#endif

enum ReportReadableTextStandaloneTests {
    /// 真机截图里的原段落（约 200 字，一段塞满月度序列）
    static let screenshotParagraph = "本期完成 94 个任务，分布在 47 天，其中高优先级只有 1 个。按月份看，8 月 22 个、9 月 23 个、10 月 15 个、11 月前 21 天 7 个；想法记录 97 条、分布在 71 天，走势差不多，9 月是最高点。11 月还没走完，21 天里 7 个不算掉队。任务具体做了什么，数据里没有，所以 9 月为什么冲高、10 月为什么回落，我判断不了。目标进度本身在快照里没有记录，长期目标推进到哪一步，这份数据回答不了。"

    static func main() {
        testSentences()
        testLeadSentences()
        testSplitParagraph()
        testNumberSpans()
        testLeadEmphasis()
        testShareDigest()
    }

    static func testShareDigest() {
        let digest = ReportShareDigest.make(
            title: "任务完成没掉档，习惯里只有英语真正停了",
            lede: "这半年任务节奏总体稳定。习惯里维生素最稳，健身在掉，英语已经停了。具体原因要结合日程再看。",
            sections: [
                .init(title: "开篇", paragraphs: ["导语后的松散段。"]),
                .init(title: "任务与想法", paragraphs: [screenshotParagraph]),
                .init(title: "打卡型习惯", paragraphs: ["维生素是唯一长期稳定的一项。本期完成 81 天。"]),
                .init(title: "计数型习惯", paragraphs: ["喝水在稳。"]),
                .init(title: "第四节", paragraphs: ["多出来的要点。"]),
            ],
            conclusions: [],
            recommendations: [(title: "先把健身拉回每周 2 次", body: "前 5 周就是这个节奏。")]
        )
        expectReportReadable(digest.points.count == 3, "要点最多 3 个且跳过「开篇」占位：\(digest.points.map(\.title))")
        expectReportReadable(digest.points.first?.title == "任务与想法", "要点按小节顺序")
        expectReportReadable((digest.points.first?.line.count ?? 0) <= 60, "要点只取首句：\(digest.points.first?.line ?? "")")
        expectReportReadable(digest.lede == "这半年任务节奏总体稳定。习惯里维生素最稳，健身在掉，英语已经停了。具体原因要结合日程再看。", "导语 80 字内整句全保留：\(digest.lede ?? "nil")")
        expectReportReadable(digest.nextStep == "先把健身拉回每周 2 次：前 5 周就是这个节奏。", "无结论条目时用首条建议：\(digest.nextStep ?? "nil")")

        let strip = HoloReportComponent(id: "c2", anchor: 1, payload: .habitStrip(.init(
            title: nil,
            rows: (0..<6).map { index in
                .init(name: "习惯\(index)", sub: nil, rateText: nil, statusLabel: "稳", tone: .good,
                      days: Array(repeating: 1, count: 3) + Array(repeating: 0, count: 4) + Array(repeating: 1, count: 7))
            },
            foldedNote: nil, startLabel: nil, endLabel: nil
        )))
        let progress = HoloReportComponent(id: "c1", anchor: -1, payload: .progress(.init(
            title: "目标进度", unit: "kg", current: 75.4, start: 78, target: 72, fraction: 0.43,
            timeFraction: 0.53, statusLabel: "略落后", tone: .warn, isStale: nil, caption: nil, projections: nil
        )))
        let withComponents = ReportShareDigest.make(title: "t", lede: nil, sections: [], conclusions: [],
                                                    recommendations: [], components: [strip, progress])
        expectReportReadable(withComponents.progress?.current == 75.4, "一屏卡取进度组件")
        expectReportReadable(withComponents.habits.count == 4, "习惯行最多 4 个：\(withComponents.habits.count)")
        expectReportReadable(withComponents.habits.first?.weekly == [3, 7], "逐日格压成每周次数：\(withComponents.habits.first?.weekly ?? [])")

        let empty = ReportShareDigest.make(title: "标题", lede: "  ", sections: [], conclusions: [], recommendations: [])
        expectReportReadable(empty.lede == nil && empty.points.isEmpty && empty.nextStep == nil, "空内容不造占位")
    }

    static func testSentences() {
        let parts = ReportReadableText.sentences("第一句。第二句！第三句")
        expectReportReadable(parts == ["第一句。", "第二句！", "第三句"], "按句末标点切句并保留标点：\(parts)")
        expectReportReadable(ReportReadableText.sentences("  ").isEmpty, "空白文本无句子")
    }

    static func testLeadSentences() {
        let s40 = String(repeating: "字", count: 39) + "。"
        let text = s40 + s40 + s40
        let lead = ReportReadableText.leadSentences(text, maxChars: 90)
        expectReportReadable(lead == s40 + s40, "90 字预算内取整句（两句 80 字）")

        let long = String(repeating: "长", count: 119) + "。后一句。"
        let first = ReportReadableText.leadSentences(long, maxChars: 90)
        expectReportReadable(first == String(repeating: "长", count: 119) + "。", "首句超预算也至少保留首句，不截断半句")
    }

    static func testSplitParagraph() {
        let parts = ReportReadableText.splitParagraph(screenshotParagraph, maxChars: 150)
        expectReportReadable(parts.count >= 2, "约 200 字的段落应拆成至少两段：\(parts.count)")
        expectReportReadable(parts.allSatisfy { $0.count <= 150 }, "每段不超过 150 字：\(parts.map(\.count))")
        expectReportReadable(parts.allSatisfy { $0.count >= 30 }, "拆出的段不能过短（≥30 字）：\(parts.map(\.count))")
        expectReportReadable(parts.joined() == screenshotParagraph, "拆分不丢字、不改字")

        let short = "体重还在降。最近三周慢了一半。"
        expectReportReadable(ReportReadableText.splitParagraph(short) == [short], "短段落原样返回")

        let oneSentence = String(repeating: "长", count: 200) + "。"
        expectReportReadable(ReportReadableText.splitParagraph(oneSentence) == [oneSentence], "单句超长不硬切")
    }

    static func testNumberSpans() {
        let text = "8 月 22 个、11-17 之后 3 天没做，约每周 3.1 次，累计 1,250 元，完成率 63%。"
        let spans = ReportReadableText.numberSpans(in: text).map { String(text[$0]) }
        expectReportReadable(spans == ["22 个", "3 天", "3.1 次", "1,250 元", "63%"], "数字+单位高亮，跳过日期（8 月、11-17）：\(spans)")

        let bare = "维生素的目标值是 4，本期完成 81 天"
        let bareSpans = ReportReadableText.numberSpans(in: bare).map { String(bare[$0]) }
        expectReportReadable(bareSpans == ["4", "81 天"], "无单位数字也高亮：\(bareSpans)")
    }

    static func testLeadEmphasis() {
        let p = "俯卧撑是最稳的一项。8 周里几乎没有断档，平均每次 32 个。"
        let range = ReportReadableText.leadEmphasisRange(in: p)
        expectReportReadable(range.map { String(p[$0]) } == "俯卧撑是最稳的一项。", "短首句（≤28 字）作为主题句加粗")

        expectReportReadable(ReportReadableText.leadEmphasisRange(in: screenshotParagraph) == nil, "长首句不整句加粗")
        expectReportReadable(ReportReadableText.leadEmphasisRange(in: "只有一句话。") == nil, "单句段不加粗（避免整段加粗）")
    }
}
