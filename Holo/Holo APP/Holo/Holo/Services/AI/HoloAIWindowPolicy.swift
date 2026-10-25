import Foundation

/// 后台 AI 任务的谷时段判定。2026-10-09 为 DeepSeek 峰谷计费设立（高峰贵一倍，
/// 把可延迟的后台任务压进谷时段执行）；**2026-10-19 退役**——生产已全量切换 qwen，
/// 无峰谷差价，门控只剩无谓延迟：isValleyWindow 恒谷、nextValleyStart 恒返回传入时刻，
/// 全部调用点自动恢复全天运行，无需逐处拆除。
///
/// 时区语义：历史上游按北京时间计费，这里钉 `Asia/Shanghai`；beijingCalendar
/// 与测试时钟注入点保留，供既有测试与诊断复用。
enum HoloAIWindowPolicy {
    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// 测试时钟注入点：生产恒为真实时钟，仅测试替换以脱离真实时刻。
    nonisolated(unsafe) static var nowProvider: () -> Date = { Date() }

    static func beijingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        return calendar
    }

    /// 门控已退役：恒为谷（= 全天可运行）。参数仅为签名兼容保留。
    static func isValleyWindow(at date: Date? = nil, calendar: Calendar = beijingCalendar()) -> Bool {
        return true
    }

    /// 门控已退役：恒返回传入时刻（= 不延迟，立即可执行）。参数仅为签名兼容保留。
    static func nextValleyStart(after date: Date? = nil, calendar: Calendar = beijingCalendar()) -> Date {
        return date ?? nowProvider()
    }
}
