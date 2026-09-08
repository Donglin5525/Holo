//
//  DateFormatters.swift
//  Holo
//
//  日期格式器统一工厂：DateFormatter 创建成本高，且视图渲染路径上「用完即弃」式
//  新建会造成滚动/刷新的持续 CPU 开销（体检 R0-40）。
//  高频路径统一从这里的缓存实例取用；低频后台路径可保留局部创建。
//  注意：各实例的 locale/timeZone 配置与其历史行为一一对应，勿随意增删。
//

import Foundation

enum HoloDateFormatters {
    /// 时:分（zh_CN 显式设定）
    static let timeZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// M/d（zh_CN 显式设定）
    static let monthDayZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f
    }()

    /// M.d（zh_CN 显式设定）
    static let dayDotZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M.d"
        return f
    }()

    /// M月d日（zh_CN 显式设定）
    static let monthDayCn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 本地化模板：M/d/EEEE（星期几）
    static let monthDayWeekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return f
    }()

    /// 本地化模板：MMM d
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// 本地化模板：年月
    static let yearMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMM")
        return f
    }()
}
