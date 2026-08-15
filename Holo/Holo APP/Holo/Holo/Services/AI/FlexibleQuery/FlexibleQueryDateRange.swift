//
//  FlexibleQueryDateRange.swift
//  Holo
//
//  Canonical calendar-day ranges for deterministic flexible queries.
//

import Foundation

nonisolated struct FlexibleQueryDateRange: Codable, Equatable, Sendable {
    let startDate: String
    let endDate: String
}

nonisolated enum FlexibleQueryDateRangeResolver {
    static func resolve(
        text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FlexibleQueryDateRange? {
        let end = calendar.startOfDay(for: now)
        let start: Date

        let recentThirtyDayMarkers = [
            "近一个月", "过去一个月",
            "近30天", "近 30 天",
            "过去30天", "过去 30 天"
        ]
        if recentThirtyDayMarkers.contains(where: { text.contains($0) }) {
            guard let recentStart = calendar.date(byAdding: .day, value: -29, to: end) else {
                return nil
            }
            start = recentStart
        } else if text.contains("上个月") {
            // 财务查询的「上个月」= 上个记账周期（与统计页同一口径）
            let startDay = FinancePeriodSettings.storedBillingCycleStartDay
            let range = BillingCycleCalculator.previousCycleRange(startDay: startDay, reference: end, calendar: calendar)
            let previousMonthEnd = calendar.date(byAdding: .day, value: -1, to: range.end) ?? end
            return FlexibleQueryDateRange(
                startDate: FlexibleQueryDateCodec.format(range.start, calendar: calendar),
                endDate: FlexibleQueryDateCodec.format(previousMonthEnd, calendar: calendar)
            )
        } else if text.contains("本月") {
            // 财务查询的「本月」= 当前记账周期（与统计页同一口径），至今天
            let startDay = FinancePeriodSettings.storedBillingCycleStartDay
            let range = BillingCycleCalculator.currentCycleRange(startDay: startDay, reference: end, calendar: calendar)
            start = range.start
        } else {
            return nil
        }

        return FlexibleQueryDateRange(
            startDate: FlexibleQueryDateCodec.format(start, calendar: calendar),
            endDate: FlexibleQueryDateCodec.format(end, calendar: calendar)
        )
    }
}

nonisolated enum FlexibleQueryPlanDateNormalizer {
    static func normalize(
        plan: FlexibleQueryPlan,
        userQuestion: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FlexibleQueryPlan {
        guard let range = FlexibleQueryDateRangeResolver.resolve(
            text: userQuestion,
            now: now,
            calendar: calendar
        ) else {
            return plan
        }

        let current = plan.filters
        let filters = FinanceQueryFilters(
            type: current.type,
            amountGreaterThan: current.amountGreaterThan,
            amountGreaterThanOrEqual: current.amountGreaterThanOrEqual,
            amountLessThan: current.amountLessThan,
            amountLessThanOrEqual: current.amountLessThanOrEqual,
            amountEqual: current.amountEqual,
            keywords: current.keywords,
            excludedKeywords: current.excludedKeywords,
            categoryNames: current.categoryNames,
            startDate: range.startDate,
            endDate: range.endDate,
            accountNames: current.accountNames,
            includeNote: current.includeNote,
            includeRemark: current.includeRemark,
            includeTags: current.includeTags,
            includeCategory: current.includeCategory
        )

        return FlexibleQueryPlan(
            domain: plan.domain,
            operation: plan.operation,
            filters: filters,
            calculation: plan.calculation,
            averageUnit: plan.averageUnit,
            sort: plan.sort,
            limit: plan.limit,
            explanationHints: plan.explanationHints
        )
    }
}

nonisolated enum FlexibleQueryDateCodec {
    static func parse(_ value: String, calendar: Calendar) throws -> Date {
        let formatter = makeFormatter(calendar: calendar)
        guard value.count == 10,
              let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw FlexibleQueryPlanValidationError.invalidDateRange
        }
        return calendar.startOfDay(for: date)
    }

    static func format(_ date: Date, calendar: Calendar) -> String {
        makeFormatter(calendar: calendar).string(from: date)
    }

    private static func makeFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
