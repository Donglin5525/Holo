//
//  TransactionDateResolver.swift
//  Holo
//
//  Resolves finance transaction dates from AI-extracted fields.
//

import Foundation

enum TransactionDateResolver {
    static func resolve(from extractedData: [String: String]?, referenceDate: Date = Date()) -> Date {
        guard let extractedData else { return referenceDate }

        for key in ["transactionDate", "date"] {
            guard let raw = extractedData[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let date = NLDateParser.parse(raw, referenceDate: referenceDate) else {
                continue
            }
            return NLDateParser.containsTimeComponent(raw)
                ? date
                : mergeDay(from: date, withTimeFrom: referenceDate)
        }

        return referenceDate
    }

    private static func mergeDay(from date: Date, withTimeFrom referenceDate: Date) -> Date {
        let calendar = Calendar.current
        var day = calendar.dateComponents([.year, .month, .day], from: date)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: referenceDate)
        day.hour = time.hour
        day.minute = time.minute
        day.second = time.second
        day.nanosecond = time.nanosecond
        return calendar.date(from: day) ?? date
    }
}
