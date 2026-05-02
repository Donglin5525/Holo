//
//  AnalysisPeriodResolver.swift
//  Holo
//
//  从 LLM 提取的 extractedData 和用户原文中解析可靠的分析日期范围
//  负责日期兜底、归一化和对比区间推导
//

import Foundation
import os.log

struct ResolvedAnalysisRequest: Equatable {
    let domain: AnalysisDomain
    let start: Date
    let end: Date
    let startDateString: String
    let endDateString: String
    let periodLabel: String
    let comparisonStart: Date?
    let comparisonEnd: Date?
    let comparisonLabel: String?
}

struct AnalysisPeriodResolver {

    private static let logger = Logger(subsystem: "com.holo.app", category: "AnalysisPeriodResolver")
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    /// 从 extractedData 和用户原文解析分析请求
    static func resolve(
        extractedData: [String: String]?,
        originalText: String,
        referenceDate: Date = Date()
    ) -> ResolvedAnalysisRequest {
        let domain = resolveDomain(extractedData: extractedData, originalText: originalText)
        let (start, end, label) = resolveDateRange(
            extractedData: extractedData,
            originalText: originalText,
            referenceDate: referenceDate
        )
        let (compStart, compEnd, compLabel) = resolveComparison(
            extractedData: extractedData,
            start: start,
            end: end,
            referenceDate: referenceDate
        )

        return ResolvedAnalysisRequest(
            domain: domain,
            start: start,
            end: end,
            startDateString: dateFmt.string(from: start),
            endDateString: dateFmt.string(from: end),
            periodLabel: label,
            comparisonStart: compStart,
            comparisonEnd: compEnd,
            comparisonLabel: compLabel
        )
    }

    // MARK: - Domain Resolution

    private static func resolveDomain(extractedData: [String: String]?, originalText: String) -> AnalysisDomain {
        if let raw = extractedData?["analysisDomain"],
           let domain = AnalysisDomain(rawValue: raw) {
            return domain
        }
        return AnalysisDomain.infer(from: originalText) ?? .crossModule
    }

    // MARK: - Date Range Resolution

    private static func resolveDateRange(
        extractedData: [String: String]?,
        originalText: String,
        referenceDate: Date
    ) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)

        // 尝试从 extractedData 解析日期
        if let startStr = extractedData?["startDate"],
           let endStr = extractedData?["endDate"],
           let s = dateFmt.date(from: startStr),
           let e = dateFmt.date(from: endStr) {
            let start = calendar.startOfDay(for: s)
            let end = calendar.startOfDay(for: e)
            if start <= end {
                let label = formatLabel(start: start, end: end)
                return (start, end, label)
            }
            logger.warning("AnalysisPeriodResolver: end < start from LLM, falling back")
        }

        // extractedData 缺失或非法，从原文关键词推断
        let lower = originalText.lowercased()

        // 年份
        if let year = extractYear(from: lower) {
            let yStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            let yEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31))!
            return (yStart, yEnd, "\(year)年")
        }

        // 去年
        if lower.contains("去年") || lower.contains("上一年") {
            guard let lastYear = calendar.date(byAdding: .year, value: -1, to: today) else {
                return fallback30Days(today: today)
            }
            let components = calendar.dateComponents([.year], from: lastYear)
            let yStart = calendar.date(from: DateComponents(year: components.year!, month: 1, day: 1))!
            let yEnd = calendar.date(from: DateComponents(year: components.year!, month: 12, day: 31))!
            return (yStart, yEnd, "\(components.year!)年")
        }

        // 今年
        if lower.contains("今年") {
            let components = calendar.dateComponents([.year], from: today)
            let yStart = calendar.date(from: DateComponents(year: components.year!, month: 1, day: 1))!
            let yEnd = calendar.date(from: DateComponents(year: components.year!, month: 12, day: 31))!
            return (yStart, yEnd, "\(components.year!)年")
        }

        // 上个月
        if lower.contains("上个月") || lower.contains("上个月") {
            guard let prevMonth = calendar.date(byAdding: .month, value: -1, to: today) else {
                return fallback30Days(today: today)
            }
            let range = calendar.dateInterval(of: .month, for: prevMonth)!
            return (range.start, calendar.date(byAdding: .day, value: -1, to: range.end)!, formatLabel(start: range.start, end: calendar.date(byAdding: .day, value: -1, to: range.end)!))
        }

        // 本月 / 这个月
        if lower.contains("本月") || lower.contains("这个月") || lower.contains("这个月") {
            let range = calendar.dateInterval(of: .month, for: today)!
            let end = calendar.date(byAdding: .day, value: -1, to: range.end)!
            return (range.start, end, "本月")
        }

        // 上周
        if lower.contains("上周") {
            guard let prevWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: today) else {
                return fallback7Days(today: today)
            }
            let range = calendar.dateInterval(of: .weekOfYear, for: prevWeek)!
            let end = calendar.date(byAdding: .day, value: -1, to: range.end)!
            return (range.start, end, formatLabel(start: range.start, end: end))
        }

        // 本周 / 这周
        if lower.contains("本周") || lower.contains("这周") || lower.contains("这周") {
            let range = calendar.dateInterval(of: .weekOfYear, for: today)!
            let end = calendar.date(byAdding: .day, value: -1, to: range.end)!
            return (range.start, end, "本周")
        }

        // 最近 N 天
        if let days = extractDays(from: lower) {
            let start = calendar.date(byAdding: .day, value: -days + 1, to: today)!
            let label = days == 30 ? "最近30天" : "最近\(days)天"
            return (start, today, label)
        }

        // 兜底：最近 30 天
        return fallback30Days(today: today)
    }

    // MARK: - Comparison Period

    private static func resolveComparison(
        extractedData: [String: String]?,
        start: Date,
        end: Date,
        referenceDate: Date
    ) -> (start: Date?, end: Date?, label: String?) {
        let calendar = Calendar.current

        // 尝试从 extractedData 解析对比日期
        if let cs = extractedData?["comparisonStartDate"],
           let ce = extractedData?["comparisonEndDate"],
           let compStart = dateFmt.date(from: cs),
           let compEnd = dateFmt.date(from: ce),
           compStart <= compEnd {
            return (calendar.startOfDay(for: compStart), calendar.startOfDay(for: compEnd), "对比期间")
        }

        // 自动推导：上一等长区间
        let duration = calendar.dateComponents([.day], from: start, to: end).day! + 1
        let compEnd = calendar.date(byAdding: .day, value: -1, to: start)!
        let compStart = calendar.date(byAdding: .day, value: -duration, to: start)!

        return (compStart, compEnd, "上一周期")
    }

    // MARK: - Helpers

    private static func extractYear(from text: String) -> Int? {
        // 匹配 "2024年" 或 "2024"
        if let range = text.range(of: #"\d{4}年"#, options: .regularExpression) {
            let numStr = text[range].replacingOccurrences(of: "年", with: "")
            return Int(numStr)
        }
        // 匹配独立的 4 位年份
        if let range = text.range(of: #"\b(20\d{2})\b"#, options: .regularExpression) {
            return Int(text[range])
        }
        return nil
    }

    private static func extractDays(from text: String) -> Int? {
        if let range = text.range(of: #"最近(\d+)天"#, options: .regularExpression) {
            let numStr = text[range].replacingOccurrences(of: "最近", with: "").replacingOccurrences(of: "天", with: "")
            return Int(numStr)
        }
        if text.contains("最近一个月") || text.contains("最近一个月") {
            return 30
        }
        if text.contains("最近一周") || text.contains("最近一周") {
            return 7
        }
        return nil
    }

    private static func formatLabel(start: Date, end: Date) -> String {
        let s = displayFmt.string(from: start)
        let e = displayFmt.string(from: end)
        return s == e ? s : "\(s) - \(e)"
    }

    private static func fallback30Days(today: Date) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: today)!
        return (start, today, "最近30天")
    }

    private static func fallback7Days(today: Date) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        return (start, today, "最近7天")
    }
}
