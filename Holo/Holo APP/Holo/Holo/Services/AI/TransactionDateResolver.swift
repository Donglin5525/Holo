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
            return date
        }

        return referenceDate
    }
}
