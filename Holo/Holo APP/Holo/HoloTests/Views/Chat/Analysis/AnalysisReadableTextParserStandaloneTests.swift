//
//  AnalysisReadableTextParserStandaloneTests.swift
//  HoloTests
//
//  Standalone checks for HoloAI analysis readability structure.
//

import Foundation

@discardableResult
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
    return true
}

@main
private enum AnalysisReadableTextParserStandaloneTests {
    static func main() {
        let sample = """
        最近 30 天，你的总支出为 20,032.73 元，日均支出 667.76 元。

        收入为 32,240 元，固定必要支出 5,426 元。其中房租 5,000 元，物业 426 元。

        可调整支出为 14,606.73 元，主要集中在购物与餐饮。
        """

        let model = AnalysisReadableTextParser.parse(
            text: sample,
            fallbackHeadline: "支出明显抬高"
        )

        expect(model.headline == "支出明显抬高", "fallback headline should be preserved")
        expect(model.facts.count == 3, "paragraphs should become three scannable facts")
        expect(model.facts[0].kicker == "支出节奏", "first fact should describe spending rhythm")
        expect(model.facts[1].kicker == "固定成本", "second fact should describe fixed cost")
        expect(model.facts[2].kicker == "可调整空间", "third fact should describe adjustable room")
        expect(model.facts[0].body.contains("20,032.73 元"), "fact body should preserve original numbers")
        expect(model.remainingText.isEmpty, "all sample paragraphs should be consumed as facts")

        let denseSample = """
        事实
        最近 30 天总支出 20032.73 元，日均 667.76 元。总收入 32240 元。固定必要支出 5426 元，其中房租 5000 元、物业 426 元。可调整支出 14606.73 元。

        支出前三分类：居住 5643 元（28.17%）、购物 4746.83 元（23.70%）、餐饮 4643.9 元（23.18%）。交通支出 543 元，其中打车 0 元，公共交通 1 次共 59 元。
        """

        let denseModel = AnalysisReadableTextParser.parse(
            text: denseSample,
            fallbackHeadline: "最近 30 天支出明显抬高，压力主要来自居住、购物和餐饮。"
        )

        expect(denseModel.facts.count == 3, "dense AI prose should still become three short facts")
        expect(denseModel.facts[0].kicker == "支出节奏", "dense first fact should describe spending rhythm")
        expect(denseModel.facts[0].body.hasPrefix("最近 30 天"), "heading text should not leak into fact body")
        expect(denseModel.facts[0].body.count < 55, "first fact should stay compact")
        expect(denseModel.facts[1].kicker == "固定成本", "dense second fact should describe fixed cost")
        expect(denseModel.facts[2].kicker == "可调整空间", "dense third fact should describe adjustable room")

        print("PASS: AnalysisReadableTextParserStandaloneTests")
    }
}
