//
//  HoloSolarTerm.swift
//  Holo
//
//  二十四节气（2026-11-23 审美七项 P4：我的积累刊头「第 N 周 · 小雪」）。
//
//  日期按 21 世纪「寿星通式」推算：day = floor(Y × 0.2422 + C) − floor(L / 4)，
//  Y 为年份后两位；小寒、大寒、立春、雨水取 L = Y − 1，其余取 L = Y。
//  个别年份与天象差一天，由例外表修正。2025–2027 共 72 个节气日与
//  香港天文台公历农历对照表逐日对账（见 HoloSolarTermTests）。
//

import Foundation

nonisolated enum HoloSolarTerm: Int, CaseIterable {
    case xiaohan, dahan, lichun, yushui, jingzhe, chunfen, qingming, guyu,
         lixia, xiaoman, mangzhong, xiazhi, xiaoshu, dashu, liqiu, chushu,
         bailu, qiufen, hanlu, shuangjiang, lidong, xiaoxue, daxue, dongzhi

    /// 通式适用的年份区间（21 世纪）
    private static let supportedYears = 2001...2099

    /// 前四个节气（小寒、大寒、立春、雨水）的 L 取 Y − 1
    private static let lookbackTermCount = 4

    /// 各节气所在公历月份（小寒 → 冬至）
    private static let months = [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12]

    /// 通式的 C 值（小寒 → 冬至）
    private static let centuryC: [Double] = [
        5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1,
        5.52, 21.04, 5.678, 21.37, 7.108, 22.83, 7.5, 23.13,
        7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94
    ]

    /// 21 世纪已知例外：年份 → [节气下标: 在通式结果上的修正天数]
    private static let corrections: [Int: [Int: Int]] = [
        2002: [HoloSolarTerm.liqiu.rawValue: 1],
        2008: [HoloSolarTerm.xiaoman.rawValue: 1],
        2016: [HoloSolarTerm.xiaoshu.rawValue: 1],
        2019: [HoloSolarTerm.xiaohan.rawValue: -1],
        2021: [HoloSolarTerm.dongzhi.rawValue: -1],
        2026: [HoloSolarTerm.yushui.rawValue: -1],
        2082: [HoloSolarTerm.dahan.rawValue: 1],
        2084: [HoloSolarTerm.chunfen.rawValue: 1],
        2089: [HoloSolarTerm.shuangjiang.rawValue: 1, HoloSolarTerm.lidong.rawValue: 1]
    ]

    /// 所在公历月份
    var month: Int {
        Self.months[rawValue]
    }

    /// 中文名（作为本地化 key；en / zh-Hant 见 Localizable.xcstrings）
    var name: String {
        switch self {
        case .xiaohan: String(localized: "小寒")
        case .dahan: String(localized: "大寒")
        case .lichun: String(localized: "立春")
        case .yushui: String(localized: "雨水")
        case .jingzhe: String(localized: "惊蛰")
        case .chunfen: String(localized: "春分")
        case .qingming: String(localized: "清明")
        case .guyu: String(localized: "谷雨")
        case .lixia: String(localized: "立夏")
        case .xiaoman: String(localized: "小满")
        case .mangzhong: String(localized: "芒种")
        case .xiazhi: String(localized: "夏至")
        case .xiaoshu: String(localized: "小暑")
        case .dashu: String(localized: "大暑")
        case .liqiu: String(localized: "立秋")
        case .chushu: String(localized: "处暑")
        case .bailu: String(localized: "白露")
        case .qiufen: String(localized: "秋分")
        case .hanlu: String(localized: "寒露")
        case .shuangjiang: String(localized: "霜降")
        case .lidong: String(localized: "立冬")
        case .xiaoxue: String(localized: "小雪")
        case .daxue: String(localized: "大雪")
        case .dongzhi: String(localized: "冬至")
        }
    }

    /// 某年该节气的公历日期（当地日历零点）；超出 21 世纪返回 nil。
    static func date(of term: HoloSolarTerm, year: Int, calendar: Calendar) -> Date? {
        guard supportedYears.contains(year) else { return nil }
        let centuryYear = year % 100
        let leapYear = term.rawValue < lookbackTermCount ? centuryYear - 1 : centuryYear
        var day = Int(floor(Double(centuryYear) * 0.2422 + centuryC[term.rawValue])) - leapYear / 4
        if let delta = corrections[year]?[term.rawValue] {
            day += delta
        }
        return calendar.date(from: DateComponents(year: year, month: term.month, day: day))
    }

    /// 当前所处的节气：取「开始日 ≤ date」的最后一个。
    /// 初值取冬至：1 月 1 日到小寒之前没有任何本年节气开始，属于上一年的冬至。
    static func current(on date: Date, calendar: Calendar) -> HoloSolarTerm {
        let year = calendar.component(.year, from: date)
        var current = HoloSolarTerm.dongzhi
        for term in HoloSolarTerm.allCases {
            // 入参 date 遮住了同名的 date(of:...)，这里必须带类型名调用
            guard let start = HoloSolarTerm.date(of: term, year: year, calendar: calendar), start <= date else {
                continue
            }
            current = term
        }
        return current
    }
}
