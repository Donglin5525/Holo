//
//  HoloPromptVariableRenderer.swift
//  Holo
//
//  Prompt 运行时变量渲染（{{todayDate}} 等）。
//  全配置可见（无 #if DEBUG），供 HoloAgentPromptProvider 等 Release 链路复用。
//  Debug 下 PromptManager 有自己的 replaceVariables，但那是 DEBUG-only；
//  Release 链路（如后端拉取的 prompt 正文）也需要做同样的变量替换。
//

import Foundation

/// 共享的 Prompt 变量渲染工具。Debug/Release 都编译。
enum HoloPromptVariableRenderer {

    /// 渲染模板中的运行时变量（{{todayDate}} / {{currentYear}} / {{currentTime}} 等）。
    /// 远程 Prompt 由后端托管，但日期/时间等客户端运行时变量仍在本地替换。
    static func renderVariables(in template: String, now: Date = Date()) -> String {
        var result = template

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
        result = result.replacingOccurrences(of: "{{todayDate}}", with: dateFormatter.string(from: now))

        let isoDateFormatter = DateFormatter()
        isoDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoDateFormatter.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "{{todayISODate}}", with: isoDateFormatter.string(from: now))

        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now
        result = result.replacingOccurrences(of: "{{thirtyDaysAgoDate}}", with: isoDateFormatter.string(from: thirtyDaysAgo))

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        result = result.replacingOccurrences(of: "{{currentYear}}", with: yearFormatter.string(from: now))

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        result = result.replacingOccurrences(of: "{{currentTime}}", with: timeFormatter.string(from: now))

        return result
    }
}
