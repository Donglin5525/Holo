import Foundation

/// 数值意图只使用能对回本轮原文的数量。这里统一处理新契约与旧意图回包。
nonisolated enum AIQuantityInput {
    static let capabilityHeader = "X-Holo-Intent-Quantity"
    static let capabilityVersion = "1"
    static let quoteKey = "quantityQuote"
    static let scopeKey = "quantityScope"

    static func accepts(_ intent: AIIntent) -> Bool {
        intent == .recordWeight || intent == .checkIn || intent == .logMetricValue
    }

    enum Issue: Error, Equatable {
        case missing, unverified, incompatibleUnit
    }

    struct SavedValue: Equatable {
        let value: Double
        let unit: String?
        var observedText: String? = nil

        var numberText: String { HoloQuantityUnit.format(value) }

        var displayText: String {
            guard let unit else { return numberText }
            let separator = unit.first?.isASCII == true && unit.first?.isLetter == true ? " " : ""
            return numberText + separator + unit
        }
    }

    private struct QuantityPart {
        let number: Double
        let unit: String?
    }

    private struct Reading {
        var range: Range<String.Index>
        var parts: [QuantityPart]
    }

    private static let numberPattern = try? NSRegularExpression(pattern:
        #"[+＋−－负負-]?(?:[0-9０-９]+(?:[.,．，][0-9０-９]+)*|(?:[零〇一二两兩三四五六七八九十百万萬亿億]|千(?![克米]))+(?:[点點][零〇一二两兩三四五六七八九]+)?)"#
    )
    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let chinesePlaces: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let chineseGroups: [Character: Int] = ["万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000]

    static func evidenceRange(in source: String, data: [String: String]?) -> Range<String.Index>? {
        quantityEvidence(in: source, data: data)?.quantity
    }

    private static func quantityEvidence(in source: String, data: [String: String]?)
        -> (scope: Range<String.Index>, quantity: Range<String.Index>)? {
        guard let quote = HoloQuantityUnit.label(data?[quoteKey]),
              let scope = HoloQuantityUnit.label(data?[scopeKey]),
              let scopeRange = uniqueRange(of: scope, in: source[...]),
              let quoteRange = uniqueRange(of: quote, in: source[scopeRange]) else { return nil }
        return (scopeRange, quoteRange)
    }

    static func resolve(
        data: [String: String]?, valueKeys: [String], originalInput: String?,
        storageUnit: String?, defaultUnit: String?, names: [String] = [], locale: Locale = .current
    ) -> Result<SavedValue, Issue> {
        let hasEvidence = data?[quoteKey] != nil || data?[scopeKey] != nil
        let legacyValue = valueKeys.compactMap { HoloQuantityUnit.label(data?[$0]) }.first
        guard hasEvidence || legacyValue != nil else { return .failure(.missing) }
        guard let source = originalInput, !source.isEmpty else { return .failure(.unverified) }
        let unitLabels = [storageUnit, defaultUnit].compactMap(HoloQuantityUnit.label)
        let namedAnchors = names.filter { !$0.isEmpty && source.contains($0) }

        if hasEvidence {
            guard let evidence = quantityEvidence(in: source, data: data),
                  let parts = wholeReading(String(source[evidence.quantity]), locale: locale) else { return .failure(.unverified) }
            let readings = scan(source, labels: unitLabels + parts.compactMap(\.unit), locale: locale)
                .filter { isObservedReading($0, in: source) }
            let scopedReadings = readings.filter { $0.range.overlaps(evidence.scope) }
            guard scopedReadings.count == 1, let reading = scopedReadings.first, reading.range == evidence.quantity,
                  namedAnchors.isEmpty || readings.count == 1
                    || namedAnchors.contains(where: source[evidence.scope].contains)
            else { return .failure(.unverified) }
            return convert(reading.parts, storageUnit: storageUnit, defaultUnit: defaultUnit, locale: locale)
                .map { SavedValue(value: $0.value, unit: $0.unit, observedText: String(source[evidence.quantity])) }
        }

        // 旧回包可能省略单位，或把原话预先换算过。以原文的唯一匹配为准。
        guard let legacyValue,
              let proposal = wholeReading(legacyValue, locale: Locale(identifier: "en_US_POSIX")) else {
            return .failure(.unverified)
        }
        let readings = scan(source, labels: unitLabels + proposal.compactMap(\.unit), locale: locale)
            .filter { isObservedReading($0, in: source) }
        let candidates = readings.filter {
            (namedAnchors.isEmpty || readings.count == 1 || namedReading($0, in: source, anchors: namedAnchors))
                && matchesLegacy($0.parts, proposal: proposal, legacyUnit: data?["unit"], defaultUnit: defaultUnit, locale: locale)
        }
        guard candidates.count == 1, let reading = candidates.first else { return .failure(.unverified) }
        return convert(reading.parts, storageUnit: storageUnit, defaultUnit: defaultUnit, locale: locale)
            .map { SavedValue(value: $0.value, unit: $0.unit, observedText: String(source[reading.range])) }
    }

    /// 对应某条待补充记录的回复只接受完整的数量表达。
    static func resolveReply(
        _ text: String, storageUnit: String?, defaultUnit: String?, locale: Locale = .current
    ) -> Result<SavedValue, Issue>? {
        let labels = Set((HoloQuantityUnit.quantityLabels + [storageUnit, defaultUnit].compactMap(HoloQuantityUnit.label))
            .compactMap(HoloQuantityUnit.normalized))
        guard let parts = wholeReading(text, locale: locale),
              parts.compactMap(\.unit).allSatisfy({ unit in
                  HoloQuantityUnit.normalized(unit).map(labels.contains) == true
              }) else { return nil }
        return convert(parts, storageUnit: storageUnit, defaultUnit: defaultUnit, locale: locale)
    }

    private static func uniqueRange(of literal: String, in text: Substring) -> Range<String.Index>? {
        guard let first = text.range(of: literal, options: .literal),
              text[first.upperBound...].range(of: literal, options: .literal) == nil else { return nil }
        return first
    }

    private static func wholeReading(_ rawText: String, locale: Locale) -> [QuantityPart]? {
        guard let text = HoloQuantityUnit.label(rawText),
              let numbers = numberPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)),
              let first = numbers.first, first.range.location == 0 else { return nil }
        var parts: [QuantityPart] = []
        for (index, match) in numbers.enumerated() {
            guard let range = Range(match.range, in: text),
                  let value = parseNumber(text[range], locale: locale) else { return nil }
            let next = numbers.dropFirst(index + 1).first.flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
            var unitText = text[range.upperBound..<next].trimmingCharacters(in: .whitespacesAndNewlines)
            if index + 1 < numbers.count, unitText.last == "又" { unitText.removeLast() }
            let rawUnit = HoloQuantityUnit.label(unitText)
            guard rawUnit?.allSatisfy({ $0.isLetter || $0 == "%" || $0 == "％" || $0.isWhitespace }) ?? true else { return nil }
            let unit = unitWithDurationContext(rawUnit, previous: parts.last, locale: locale)
            parts.append(QuantityPart(number: value, unit: unit))
        }
        return isValidCompound(parts, locale: locale) ? parts : nil
    }

    private static func scan(_ text: String, labels: [String], locale: Locale) -> [Reading] {
        let recognized = Set((HoloQuantityUnit.quantityLabels + labels).compactMap(HoloQuantityUnit.normalized))
        let longestUnit = recognized.map(\.count).max() ?? 0
        var readings: [Reading] = []
        for match in numberPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let numberRange = Range(match.range, in: text),
                  !continuesNumericExpression(numberRange, in: text),
                  let value = parseNumber(text[numberRange], locale: locale) else { continue }
            let tail = text[numberRange.upperBound...].drop(while: \.isWhitespace)
            let prefix = unitPrefix(in: tail, recognized: recognized, maxLength: longestUnit)
            if prefix == nil, let next = tail.first, !isQuantityBoundary(next) { continue }
            if prefix == nil, numberRange.lowerBound > text.startIndex,
               ":：/／".contains(text[text.index(before: numberRange.lowerBound)]) { continue }
            let rawUnit = prefix.map(String.init)
            let end = prefix?.endIndex ?? numberRange.upperBound
            if let last = readings.last, last.range.upperBound <= numberRange.lowerBound,
               text[last.range.upperBound..<numberRange.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "又" }),
               durationFactor(last.parts.last?.unit, locale: locale) != nil,
               let unit = unitWithDurationContext(rawUnit, previous: last.parts.last, locale: locale),
               durationFactor(unit, locale: locale) != nil {
                let part = QuantityPart(number: value, unit: unit)
                readings[readings.count - 1] = Reading(
                    range: last.range.lowerBound..<end, parts: last.parts + [part]
                )
            } else {
                readings.append(Reading(range: numberRange.lowerBound..<end, parts: [QuantityPart(number: value, unit: rawUnit)]))
            }
        }
        return readings.filter { isValidCompound($0.parts, locale: locale) }
    }

    private static func unitPrefix(in text: Substring, recognized: Set<String>, maxLength: Int) -> Substring? {
        for count in stride(from: text.prefix(maxLength).count, through: 1, by: -1) {
            let candidate = text.prefix(count)
            guard let key = HoloQuantityUnit.normalized(String(candidate)), recognized.contains(key),
                  candidate.last?.isWhitespace == false else { continue }
            if let next = text[candidate.endIndex...].first {
                if "/／每".contains(next) || (next.isASCII && next.isLetter && key.last?.isASCII == true) {
                    return nil
                }
                if next == "力", HoloQuantityUnit.isMass(key) { return nil }
            }
            return candidate
        }
        return nil
    }

    private static func isQuantityBoundary(_ character: Character) -> Bool {
        ",，。．.!！?？;；、)]）】」”\"".contains(character)
    }

    /// 分数、比例、时刻和科学记数的尾部不能单独成为一笔数值。
    private static func continuesNumericExpression(_ range: Range<String.Index>, in text: String) -> Bool {
        let prefix = text[..<range.lowerBound]
        if prefix.last?.isNumber == true, let start = text[range].first, "+＋−－-".contains(start) { return true }
        guard let separator = prefix.last, ":：/／eE".contains(separator) else { return false }
        return prefix.dropLast().last?.isNumber == true
    }

    private static let boundaries = ",，、。；;！!？?\n"

    private static func isObservedReading(_ reading: Reading, in text: String) -> Bool {
        let before = text[..<reading.range.lowerBound]
        let prefix = String(before.reversed().prefix { !boundaries.contains($0) }.reversed())
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ":： \t"))
        if ["目标", "目標"].contains(where: trimmedPrefix.hasSuffix)
            || ["目标是", "目標是", "目标体重", "目標體重", "计划", "計畫", "打算", "希望", "减到", "減到",
                "想减", "想減", "没做", "沒做", "没喝", "沒喝", "没有做", "沒有做"].contains(where: prefix.contains) {
            return false
        }
        return true
    }

    private static func namedReading(_ reading: Reading, in text: String, anchors: [String]) -> Bool {
        let before = text[..<reading.range.lowerBound].reversed().prefix { !boundaries.contains($0) }.reversed()
        let after = text[reading.range.upperBound...].prefix { !boundaries.contains($0) }
        let clause = String(before) + String(text[reading.range]) + String(after)
        return anchors.contains(where: clause.contains)
    }

    private static func durationFactor(_ unit: String?, locale: Locale) -> Double? {
        guard let standard = HoloQuantityUnit.standard(unit, locale: locale), standard.dimension == .duration else { return nil }
        return standard.factor
    }

    private static func unitWithDurationContext(_ unit: String?, previous: QuantityPart?, locale: Locale) -> String? {
        // 单说「分」也可指评分。紧接小时的时长表达才把它解释成分钟。
        if HoloQuantityUnit.normalized(unit) == "分", (durationFactor(previous?.unit, locale: locale) ?? 0) > 60 {
            return "分钟"
        }
        return unit
    }

    private static func isValidCompound(_ parts: [QuantityPart], locale: Locale) -> Bool {
        guard parts.count > 1 else { return true }
        let factors = parts.compactMap { durationFactor($0.unit, locale: locale) }
        return factors.count == parts.count && parts.allSatisfy { $0.number >= 0 }
            && zip(factors, factors.dropFirst()).allSatisfy { previous, next in previous > next }
    }

    private static func matchesLegacy(_ parts: [QuantityPart], proposal: [QuantityPart], legacyUnit: String?,
                                      defaultUnit: String?, locale: Locale) -> Bool {
        if parts.count == proposal.count,
           zip(parts, proposal).allSatisfy({ observed, guessed in
               observed.number == guessed.number
                   && (guessed.unit == nil || HoloQuantityUnit.factor(from: observed.unit, to: guessed.unit, locale: locale) == 1)
           }) { return true }
        guard let item = proposal.first, proposal.count == 1,
              let unit = item.unit ?? legacyUnit ?? defaultUnit,
              case .success(let converted) = convert(parts, storageUnit: unit, defaultUnit: nil, locale: locale) else { return false }
        return abs(converted.value - item.number) <= max(1, abs(item.number)) * 1e-10
    }

    private static func convert(_ parts: [QuantityPart], storageUnit rawStorage: String?, defaultUnit: String?,
                                locale: Locale) -> Result<SavedValue, Issue> {
        let storage = HoloQuantityUnit.label(rawStorage)
        var sum = 0.0
        for part in parts {
            let inputUnit = part.unit ?? HoloQuantityUnit.label(defaultUnit) ?? storage
            guard let factor = HoloQuantityUnit.factor(from: inputUnit, to: storage, locale: locale) else {
                return .failure(.incompatibleUnit)
            }
            sum += part.number * factor
        }
        guard sum.isFinite else { return .failure(.unverified) }
        return .success(SavedValue(value: sum, unit: storage))
    }

    private static func parseNumber(_ raw: Substring, locale: Locale) -> Double? {
        var value = raw.precomposedStringWithCompatibilityMapping
        let negative = value.first.map { "-−负負".contains($0) } ?? false
        if negative || value.first == "+" { value.removeFirst() }
        let absolute = value.first?.isASCII == true
            ? parseArabic(value, locale: locale)
            : parseChinese(value)
        guard let absolute, absolute.isFinite else { return nil }
        return negative ? -absolute : absolute
    }

    private static func parseArabic(_ text: String, locale: Locale) -> Double? {
        let decimal: Character = locale.decimalSeparator == "," ? "," : "."
        let grouping: Character = decimal == "," ? "." : ","
        let fields = text.split(separator: decimal, omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count), let integer = fields.first else { return nil }
        let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
        if groups.count > 1 {
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let canonical = groups.joined() + (fields.count == 2 ? "." + fields[1] : "")
        return Double(canonical)
    }

    private static func parseChinese(_ text: String) -> Double? {
        let fields = text.split(omittingEmptySubsequences: false, whereSeparator: { "点點".contains($0) })
        guard (1...2).contains(fields.count), let integer = fields.first, !integer.isEmpty else { return nil }
        var value = 0.0
        if integer.allSatisfy({ chineseDigits[$0] != nil }) {
            // 「三五」可能是概数。带零的逐位读法和小数部分可以明确按位读取。
            guard integer.count != 2 || integer.contains(where: { chineseDigits[$0] == 0 }) else { return nil }
            value = integer.reduce(0) { $0 * 10 + Double(chineseDigits[$1] ?? 0) }
        } else {
            // 「一百六」可能省略了「十」。确指 106 时需要「一百零六」。
            guard integer.range(of: #"[百千万萬亿億][一二两兩三四五六七八九](?:[万萬亿億]|$)"#,
                                options: .regularExpression) == nil else { return nil }
            var section = 0.0
            var digit: Int?
            var previousPlace = 10_000
            var previousGroup = Int.max
            for character in integer {
                if let next = chineseDigits[character] {
                    guard digit == nil else { return nil }
                    digit = next == 0 ? nil : next
                } else if let place = chinesePlaces[character] {
                    guard place < previousPlace, digit != nil || (place == 10 && section == 0) else { return nil }
                    section += Double((digit ?? 1) * place)
                    digit = nil
                    previousPlace = place
                } else if let group = chineseGroups[character] {
                    let subtotal = section + Double(digit ?? 0)
                    guard group < previousGroup, subtotal > 0 else { return nil }
                    value += subtotal * Double(group)
                    section = 0
                    digit = nil
                    previousPlace = 10_000
                    previousGroup = group
                } else {
                    return nil
                }
            }
            value += section + Double(digit ?? 0)
        }
        if fields.count == 2 {
            let digits = fields[1].compactMap { chineseDigits[$0] }
            guard !digits.isEmpty, digits.count == fields[1].count,
                  let fraction = Double("0." + digits.map(String.init).joined()) else { return nil }
            value += fraction
        }
        return value
    }
}
