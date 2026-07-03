//
//  ChatTimeStampSeparator.swift
//  Holo
//
//  对话时间分隔条（微信 / IM 风格）
//  相邻消息间隔 ≥ 5 分钟时，在较新消息上方居中显示时间，避免每条消息都打时间戳
//

import SwiftUI

struct ChatTimeStampSeparator: View {
    let date: Date

    var body: some View {
        Text(formattedText)
            .font(.system(size: 11))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.holoTextSecondary.opacity(0.08))
            .cornerRadius(8)
    }

    /// 时间文本（实例属性，MainActor 隔离，安全调用 DateFormatter）
    /// 遵守编码约定：DateFormatter + zh_CN，禁止 Text(date, style:) / date.formatted()
    private var formattedText: String {
        let time = Self.timeFormatter.string(from: date)
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return time
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(time)"
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.monthDayFormatter.string(from: date)
        }
        return Self.fullDateFormatter.string(from: date)
    }

    /// 判断当前消息是否需要显示时间分隔条
    /// - Parameter previous: 上一条消息时间戳；nil 表示首条消息
    /// - Returns: 首条消息，或与上一条间隔 ≥ 5 分钟时返回 true
    static func shouldShow(current: Date, previous: Date?) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) >= 300
    }

    // MARK: - Date Formatters

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}
