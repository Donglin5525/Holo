//
//  HoloScheduleTool.swift
//  Holo
//
//  Agent V3.1 — 系统日历日程工具（一期只读）
//  查询某日日程/空闲时段，供对话排时与周规划避让使用。
//  日历未开启或未授权时返回空态语义（NO_SCHEDULE_DATA），不报错打断对话。
//  本文件零 EventKit 依赖：只消费 tool-local 值类型，生产 DataSource 负责桥接 ScheduleStore。
//

import Foundation

// MARK: - Value Types (tool-local)

struct HoloScheduleToolEvent: Codable, Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarTitle: String

    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

// MARK: - DataSource Protocol

protocol HoloScheduleDataSource: Sendable {
    /// 拉取 [startDate, startDate + days) 内的日程；nil = 日历未开启/未授权（空态）
    func events(from startDate: Date, days: Int) async -> [HoloScheduleToolEvent]?
}

// MARK: - Tool

struct HoloScheduleTool: HoloDataTool {

    /// 空闲段计算的工作时间窗（本地时刻）
    private static let workdayStartHour = 8
    private static let workdayEndHour = 22

    let descriptor = HoloToolDescriptor(
        name: "schedule",
        description: "系统日历日程查询（某日日程列表 / 时间占用 / 工作时段空闲段），用于回答时间安排与排任务时避开会议",
        supportedQueries: ["today_schedule", "day_schedule", "free_slots"],
        supportedTimeRanges: ["recent", "7d", "14d"],
        outputMetrics: [
            "schedule.day.event_count",
            "schedule.day.busy_minutes",
            "schedule.day.longest_free_minutes"
        ],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloScheduleDataSource

    init(dataSource: HoloScheduleDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的日程查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        // day_schedule / free_slots：取请求范围首日（无范围默认今天）
        let calendar = Calendar.current
        let anchorDay = calendar.startOfDay(
            for: request.timeRange?.start ?? Date()
        )

        // today_schedule 恒为今天；其余用锚定日
        let day = request.query == "today_schedule" ? calendar.startOfDay(for: Date()) : anchorDay
        let events = await dataSource.events(from: day, days: 1)

        guard let events else {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_SCHEDULE_DATA", message: "系统日历未开启或未授权，暂无日程数据")],
                error: nil,
                sensitivity: .sensitive
            )
        }

        let timed = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        let busyMinutes = timed.reduce(0) { $0 + $1.durationMinutes }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        switch request.query {
        case "today_schedule", "day_schedule":
            if events.isEmpty {
                return HoloDataToolResult(
                    toolRequestID: request.id,
                    tool: request.tool,
                    status: .empty,
                    coverage: nil,
                    metrics: [],
                    events: [],
                    warnings: [HoloToolWarning(code: "NO_SCHEDULE_DATA", message: "该日没有日程")],
                    error: nil,
                    sensitivity: .sensitive
                )
            }
            let metrics: [HoloMetric] = [
                HoloMetric(metricKey: "schedule.day.event_count", value: Double(events.count), unit: "场", baselineValue: nil, comparison: nil),
                HoloMetric(metricKey: "schedule.day.busy_minutes", value: Double(busyMinutes), unit: "分钟", baselineValue: nil, comparison: nil)
            ]
            let evidence = events.enumerated().map { index, event in
                HoloEvidenceEvent(
                    id: "schedule-\(request.id)-\(index)",
                    occurredAt: event.start,
                    metricKey: "schedule.day.event_count",
                    metricValue: 1,
                    excerpt: event.isAllDay
                        ? "全天：\(event.title)（\(event.calendarTitle)）"
                        : "\(timeFormatter.string(from: event.start))-\(timeFormatter.string(from: event.end)) \(event.title)（\(event.calendarTitle)）"
                )
            }
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .success,
                coverage: nil,
                metrics: metrics,
                events: evidence,
                warnings: [],
                error: nil,
                sensitivity: .sensitive
            )

        case "free_slots":
            let slots = Self.freeSlots(on: day, timedEvents: timed, calendar: calendar)
            let longest = slots.map { Int($0.duration / 60) }.max() ?? 0
            let slotDescriptions = slots
                .filter { $0.duration >= 30 * 60 }
                .map { "\(timeFormatter.string(from: $0.start))-\(timeFormatter.string(from: $0.end))" }
            let metrics: [HoloMetric] = [
                HoloMetric(metricKey: "schedule.day.longest_free_minutes", value: Double(longest), unit: "分钟", baselineValue: nil, comparison: nil)
            ]
            let evidence = [HoloEvidenceEvent(
                id: "schedule-free-\(request.id)",
                occurredAt: day,
                metricKey: "schedule.day.longest_free_minutes",
                metricValue: Double(longest),
                excerpt: slots.isEmpty
                    ? "工作时段（\(Self.workdayStartHour):00-\(Self.workdayEndHour):00）已被日程占满"
                    : "可安排时段：\(slotDescriptions.joined(separator: "、"))（工作时段 \(Self.workdayStartHour):00-\(Self.workdayEndHour):00 内、时长 ≥30 分钟）"
            )]
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: slots.isEmpty && timed.isEmpty ? .empty : .success,
                coverage: nil,
                metrics: metrics,
                events: evidence,
                warnings: timed.isEmpty ? [HoloToolWarning(code: "NO_SCHEDULE_DATA", message: "该日没有日程，全天空闲")] : [],
                error: nil,
                sensitivity: .sensitive
            )

        default:
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .error,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [],
                error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: "不支持的日程查询：\(request.query)", recoverable: true)
            )
        }
    }

    // MARK: - 空闲段计算

    struct FreeSlot: Equatable {
        var start: Date
        var end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// 工作时段（8:00–22:00）内减去定时日程占用后的空闲段
    static func freeSlots(on day: Date, timedEvents: [HoloScheduleToolEvent], calendar: Calendar) -> [FreeSlot] {
        var windowStart = calendar.date(bySettingHour: workdayStartHour, minute: 0, second: 0, of: day) ?? day
        let windowEnd = calendar.date(bySettingHour: workdayEndHour, minute: 0, second: 0, of: day) ?? day
        var slots: [FreeSlot] = []
        for event in timedEvents where event.end > windowStart && event.start < windowEnd {
            if event.start > windowStart {
                slots.append(FreeSlot(start: windowStart, end: event.start))
            }
            windowStart = max(windowStart, event.end)
            if windowStart >= windowEnd { break }
        }
        if windowStart < windowEnd {
            slots.append(FreeSlot(start: windowStart, end: windowEnd))
        }
        return slots
    }
}
