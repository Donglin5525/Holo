import Foundation

@main
struct HoloChartGeometryStandaloneTests {
    static func main() {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { fatalError(message) }
        }
        // 旧同比图的具体回归：300pt / 12 桶，18pt 仍属于第一格。
        expect(HoloChartGeometry.bucketIndex(x: 18, width: 300, count: 12) == 0, "同比第一格不能提早跳到第二格")
        for width: CGFloat in [240, 320, 768, 1024] {
            for count in [1, 2, 7, 12, 24, 31, 366] {
                let pitch = width / CGFloat(count)
                let positions = (0..<count).map { (CGFloat($0) + 0.5) * pitch }
                for index in 0..<count {
                    for offset: CGFloat in [0.01, 0.5, 0.99] {
                        let x = (CGFloat(index) + offset) * pitch
                        expect(HoloChartGeometry.bucketIndex(x: x, width: width, count: count) == index, "每格中心与边缘应命中本格")
                        expect(HoloChartGeometry.nearestIndex(x: x, positions: positions) == index, "绘图区实际中心与槽位选择必须一致")
                    }
                }
                expect(HoloChartGeometry.bucketIndex(x: width, width: width, count: count) == count - 1, "右边缘属于最后一格")
                expect(HoloChartGeometry.bucketIndex(x: -1, width: width, count: count) == nil, "初始触摸不得越界")
                expect(HoloChartGeometry.bucketIndex(x: width + 1, width: width, count: count) == nil, "初始触摸不得越界")
                expect(HoloChartGeometry.bucketIndex(x: width + 50, width: width, count: count, clamped: true) == count - 1, "已开始的滑选钳制到末格")
                for series in [1, 2] {
                    let bar = HoloChartGeometry.barWidth(plotWidth: width, count: count, seriesCount: series)
                    expect(bar <= (series == 1 ? 18 : 10), "柱宽不得超过上限")
                    expect(bar * CGFloat(series) <= pitch, "双柱不得伸出所属日期槽")
                }
            }
        }
        let size = CGSize(width: 312, height: 182)
        for week in 0..<12 {
            for weekday in 0..<7 {
                let point = CGPoint(x: (CGFloat(week) + 0.5) * 26, y: (CGFloat(weekday) + 0.5) * 26)
                expect(HoloChartGeometry.heatmapIndex(point: point, size: size, weeks: 12) == week * 7 + weekday, "热力图横纵命中须与日期布局一致")
            }
        }
        expect(HoloChartGeometry.heatmapIndex(point: CGPoint(x: -1, y: 20), size: size, weeks: 12) == nil, "标签区域不能选日期")
        expect(HoloChartGeometry.heatmapIndex(point: CGPoint(x: 10, y: 183), size: size, weeks: 12) == nil, "热力图下方不能选日期")
        expect((0...11).map(HoloChartGeometry.countLevel) == [0,1,2,2,3,3,4,4,4,4,5,5], "热力色阶稳定，0 和 1 必须不同")
        expect(HoloChartGeometry.contiguousSegments(valid: [true,false,true,true,false,true]) == [[0],[2,3],[5]], "缺失不能连线，孤点保留")
        expect(HoloChartGeometry.contiguousSegments(valid: [false,false]).isEmpty, "全缺失不能制造假曲线")
        expect(HoloChartGeometry.contiguousSegments(valid: [true,true,true]) == [[0,1,2]], "真实零值按有效样本连线")
        let positions: [CGFloat] = [5, 20, 120]
        expect(HoloChartGeometry.nearestIndex(x: 60, positions: positions) == 1, "不等距心率使用实际采样坐标")
        expect(HoloChartGeometry.nearestIndex(x: 0, positions: [.infinity]) == nil, "未布局时不能选到假数据")
        let amountDomain = HoloChartGeometry.niceDomain(values: [0, 10, 1000000], includesZero: true)
        expect(amountDomain.lowerBound == 0 && amountDomain.upperBound > 1000000, "金额不截断尖峰")
        let negativeDomain = HoloChartGeometry.niceDomain(values: [-500, -20], includesZero: true)
        expect(negativeDomain.lowerBound < -500 && negativeDomain.upperBound > 0, "负值和零基线完整保留")
        let pointDomain = HoloChartGeometry.niceDomain(values: [7], includesZero: false)
        expect(pointDomain.lowerBound < 7 && pointDomain.upperBound > 7, "单点上下留白")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let days = HoloChartGeometry.dates(from: start, through: end, calendar: calendar)
        expect(days.count == 4, "夏令时切换仍是四个自然日")
        expect(days.map { calendar.component(.day, from: $0) } == [7,8,9,10], "不能按固定秒数错过日期")
        print("图表几何回归通过：\(assertions) 项断言")
    }
}
