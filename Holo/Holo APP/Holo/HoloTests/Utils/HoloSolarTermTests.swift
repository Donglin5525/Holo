//
//  HoloSolarTermTests.swift
//  HoloTests
//
//  节气日期对账（2026-11-23 审美七项 P4：我的积累刊头「第 N 周 · 小雪」）。
//
//  期望值来源：香港天文台《公历与农历日期对照表》
//    https://www.hko.gov.hk/tc/gts/time/calendar/text/files/T2025c.txt
//    （2026、2027 把文件名里的年份换掉即可）
//  2025–2027 共 72 个节气逐一固定断言；通式与官方表不一致的年份在例外表补齐。
//

import XCTest
@testable import Holo

final class HoloSolarTermTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }

    private func day(_ term: HoloSolarTerm, year: Int) -> (month: Int, day: Int)? {
        guard let date = HoloSolarTerm.date(of: term, year: year, calendar: calendar) else { return nil }
        let comps = calendar.dateComponents([.month, .day], from: date)
        return (comps.month ?? 0, comps.day ?? 0)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? .distantPast
    }

    /// (节气, 月, 日)
    private typealias Fixed = (HoloSolarTerm, Int, Int)

    private let expected2025: [Fixed] = [
        (.xiaohan, 1, 5), (.dahan, 1, 20), (.lichun, 2, 3), (.yushui, 2, 18),
        (.jingzhe, 3, 5), (.chunfen, 3, 20), (.qingming, 4, 4), (.guyu, 4, 20),
        (.lixia, 5, 5), (.xiaoman, 5, 21), (.mangzhong, 6, 5), (.xiazhi, 6, 21),
        (.xiaoshu, 7, 7), (.dashu, 7, 22), (.liqiu, 8, 7), (.chushu, 8, 23),
        (.bailu, 9, 7), (.qiufen, 9, 23), (.hanlu, 10, 8), (.shuangjiang, 10, 23),
        (.lidong, 11, 7), (.xiaoxue, 11, 22), (.daxue, 12, 7), (.dongzhi, 12, 21)
    ]

    private let expected2026: [Fixed] = [
        (.xiaohan, 1, 5), (.dahan, 1, 20), (.lichun, 2, 4), (.yushui, 2, 18),
        (.jingzhe, 3, 5), (.chunfen, 3, 20), (.qingming, 4, 5), (.guyu, 4, 20),
        (.lixia, 5, 5), (.xiaoman, 5, 21), (.mangzhong, 6, 5), (.xiazhi, 6, 21),
        (.xiaoshu, 7, 7), (.dashu, 7, 23), (.liqiu, 8, 7), (.chushu, 8, 23),
        (.bailu, 9, 7), (.qiufen, 9, 23), (.hanlu, 10, 8), (.shuangjiang, 10, 23),
        (.lidong, 11, 7), (.xiaoxue, 11, 22), (.daxue, 12, 7), (.dongzhi, 12, 22)
    ]

    private let expected2027: [Fixed] = [
        (.xiaohan, 1, 5), (.dahan, 1, 20), (.lichun, 2, 4), (.yushui, 2, 19),
        (.jingzhe, 3, 6), (.chunfen, 3, 21), (.qingming, 4, 5), (.guyu, 4, 20),
        (.lixia, 5, 6), (.xiaoman, 5, 21), (.mangzhong, 6, 6), (.xiazhi, 6, 21),
        (.xiaoshu, 7, 7), (.dashu, 7, 23), (.liqiu, 8, 8), (.chushu, 8, 23),
        (.bailu, 9, 8), (.qiufen, 9, 23), (.hanlu, 10, 8), (.shuangjiang, 10, 23),
        (.lidong, 11, 7), (.xiaoxue, 11, 22), (.daxue, 12, 7), (.dongzhi, 12, 22)
    ]

    private func assertMatches(_ expected: [Fixed], year: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected.count, 24, "每年 24 个节气", file: file, line: line)
        for (term, month, dayNumber) in expected {
            XCTAssertEqual(day(term, year: year)?.month, month,
                           "\(year) \(term) 月份", file: file, line: line)
            XCTAssertEqual(day(term, year: year)?.day, dayNumber,
                           "\(year) \(term) 日期", file: file, line: line)
        }
    }

    func test_2025_二十四节气与官方表一致() {
        assertMatches(expected2025, year: 2025)
    }

    func test_2026_二十四节气与官方表一致() {
        assertMatches(expected2026, year: 2026)
    }

    func test_2027_二十四节气与官方表一致() {
        assertMatches(expected2027, year: 2027)
    }

    func test_例外表修正生效() {
        // 通式原始结果 → 例外修正后（与官方表一致）
        XCTAssertEqual(day(.xiaohan, year: 2019)?.day, 5, "2019 小寒 −1")
        XCTAssertEqual(day(.dongzhi, year: 2021)?.day, 21, "2021 冬至 −1")
        XCTAssertEqual(day(.xiaoshu, year: 2016)?.day, 7, "2016 小暑 +1")
        XCTAssertEqual(day(.xiaoman, year: 2008)?.day, 21, "2008 小满 +1")
        XCTAssertEqual(day(.liqiu, year: 2002)?.day, 8, "2002 立秋 +1")
        XCTAssertEqual(day(.yushui, year: 2026)?.day, 18, "2026 雨水 −1")
    }

    func test_当前节气_小雪当天与之后() {
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 11, 22), calendar: calendar), .xiaoxue, "小雪当天即切换")
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 11, 23), calendar: calendar), .xiaoxue)
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 12, 6), calendar: calendar), .xiaoxue, "大雪前一天")
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 12, 7), calendar: calendar), .daxue, "大雪当天")
    }

    func test_当前节气_一月二日属上一年冬至() {
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 1, 1), calendar: calendar), .dongzhi)
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 1, 2), calendar: calendar), .dongzhi)
        XCTAssertEqual(HoloSolarTerm.current(on: date(2026, 1, 5), calendar: calendar), .xiaohan, "小寒当天")
    }

    func test_当前节气_全年无断档() {
        // 2026 年前后每一天都落在「开始日 ≤ 当天」的最后一个节气里
        //（独立重算一遍期望值：上一年冬至 + 本年 24 个节气里取最晚的已开始者）
        var cursor = date(2025, 12, 15)
        let end = date(2027, 1, 10)
        var checked = 0
        while cursor <= end {
            let year = calendar.component(.year, from: cursor)
            var started: [(Date, HoloSolarTerm)] = []
            if let previous = HoloSolarTerm.date(of: .dongzhi, year: year - 1, calendar: calendar) {
                started.append((previous, .dongzhi))
            }
            for term in HoloSolarTerm.allCases {
                if let start = HoloSolarTerm.date(of: term, year: year, calendar: calendar) {
                    started.append((start, term))
                }
            }
            let expected = started.filter { $0.0 <= cursor }.max { $0.0 < $1.0 }?.1
            XCTAssertEqual(HoloSolarTerm.current(on: cursor, calendar: calendar), expected)
            checked += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        XCTAssertGreaterThan(checked, 390, "应覆盖约 13 个月")
    }

    func test_超出21世纪返回nil() {
        XCTAssertNil(HoloSolarTerm.date(of: .lichun, year: 2000, calendar: calendar))
        XCTAssertNil(HoloSolarTerm.date(of: .lichun, year: 2100, calendar: calendar))
        XCTAssertNotNil(HoloSolarTerm.date(of: .lichun, year: 2001, calendar: calendar))
    }

    func test_月份与节气一一对应() {
        XCTAssertEqual(HoloSolarTerm.allCases.map(\.month),
                       [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12])
    }
}
