//
//  HoloChartRenderSmokeTests.swift
//  HoloTests
//
//  2026-11-15 图表新图型渲染对拍（暖光对拍同款通道）：
//  单测把组件按固定尺寸渲成 PNG 落 /tmp，供只读判读代理核验颜色/标签/布局——
//  单测断言只保证「渲染非空」，颜色对错由判读回合把关（真机全蓝事故的防线）。
//

import XCTest
import SwiftUI
@testable import Holo

final class HoloChartRenderSmokeTests: XCTestCase {

    @MainActor
    func testRenderNewChartComponentsToPNG() throws {
        let calendar = Calendar(identifier: .gregorian)
        let origin = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)) ?? Date()

        // 1) 构成趋势（堆叠面积）：三层不同色 + 全月份标签 + 文案
        let stackBuckets = (1...6).map { HoloStackedAreaBucket(id: "m\($0)", label: "\($0)月", detail: "2026 年 \($0) 月") }
        let stackSeries = [
            HoloStackedAreaSeries(id: "base", title: "居住", color: .holoChart1, values: [220, 220, 220, 220, 220, 220]),
            HoloStackedAreaSeries(id: "mid", title: "餐饮", color: .holoChart2, values: [118, 124, 109, 128, 115, 128]),
            HoloStackedAreaSeries(id: "top", title: "其他", color: .holoChart5, values: [202, 132, 134, 142, 147, 178])
        ]
        let stacked = HoloStackedAreaChart(buckets: stackBuckets, series: stackSeries,
                                           selection: .constant("m6"), summary: "近 6 月")
        try render(stacked, size: CGSize(width: 390, height: 340), to: "/tmp/holo-chart-render-stacked.png")

        // 2) 瀑布（V4 横向瀑布，真实极端量级 7.4 万存量 vs 千元级流水）
        let waterfall = HoloWaterfallChart(items: [
            .init(id: "open", label: "期初", total: 74_660.68),
            .init(id: "inc-top", label: "投资理财", delta: 6_150),
            .init(id: "inc-rest", label: "其他收入", delta: 3_400),
            .init(id: "exp-1", label: "居住", delta: -5_426.22),
            .init(id: "exp-2", label: "餐饮", delta: -2_208.30),
            .init(id: "exp-3", label: "其他", delta: -1_074.90),
            .init(id: "exp-rest", label: "其余 3 类", delta: -1_526.53),
            .init(id: "close", label: "期末", total: 73_974.73)
        ], valueText: { String(format: "¥%.2f", $0) })
        try render(waterfall, size: CGSize(width: 390, height: 420), to: "/tmp/holo-chart-render-waterfall.png")

        // 3) 迷你趋势：读数行 + 末点样式 + 首尾日期
        let offsets = [0, 2, 5, 9, 14, 20, 27]
        let values = [38.5, 38.1, 37.6, 37.9, 37.2, 36.8, 36.4]
        let mini = HoloMiniTrendChart(
            points: offsets.indices.map {
                .init(date: calendar.date(byAdding: .day, value: offsets[$0], to: origin) ?? origin, value: values[$0])
            },
            color: .holoChart6, title: "样例测量", valueText: { String(format: "%.1f", $0) })
        try render(mini, size: CGSize(width: 390, height: 150), to: "/tmp/holo-chart-render-mini.png")

        // 3b) 迷你趋势单点稀疏态（唯一记录，必须定径 10pt，不能撑满绘图区）
        let miniSingle = HoloMiniTrendChart(
            points: [.init(date: origin, value: 50)],
            color: .holoChart6, title: "深蹲", valueText: { "\(Int($0)) 个" })
        try render(miniSingle, size: CGSize(width: 390, height: 100), to: "/tmp/holo-chart-render-mini-single.png", minBytes: 4_000)

        // 4) 增强组合：参考线 + 上期淡影 + 图例开关胶囊
        let comboBuckets = (0..<6).map {
            HoloChartBucket(id: "r-\($0)", label: "\($0 + 1)日", values: [Double($0 * 10 + 15)])
        }
        let combo = HoloBarChart(
            buckets: comboBuckets,
            series: [.init(id: "only", title: "支出", color: .holoChart2)],
            selection: .constant(nil),
            rules: [HoloChartRule(value: 55, label: "月预算 55", color: .holoPrimary)],
            comparison: HoloChartComparison(ghostValues: [8, 18, 28, 38, 48, 58]),
            legendToggle: true)
        try render(combo, size: CGSize(width: 390, height: 300), to: "/tmp/holo-chart-render-combo.png")
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize, to path: String, minBytes: Int = 10_000) throws {
        // 显式浅色环境 + 垫白底：ImageRenderer 默认透明底（PNG 透明被读成黑底/灰字发糊）
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "渲染失败: \(path)")
        XCTAssertGreaterThan(image.size.width * image.size.height, 100 * 100, "渲染面积异常（疑似空白）: \(path)")
        let data = try XCTUnwrap(image.pngData(), "PNG 编码失败: \(path)")
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, minBytes, "PNG 过小（疑似空白）: \(path)")
    }
}
