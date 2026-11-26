import Foundation

/// 生活数值的存储单位。自定义量词只能在同一口径下原样使用。
nonisolated enum HoloQuantityUnit {
    enum Dimension: Sendable {
        case mass, distance, duration, volume, occurrence
    }

    struct Standard: Sendable {
        let dimension: Dimension
        let factor: Double
        let aliases: [String]
    }

    private static let standards: [Standard] = [
        .init(dimension: .mass, factor: 1, aliases: ["kg", "公斤", "千克", "kilogram", "kilograms", "kilo", "kilos"]),
        .init(dimension: .mass, factor: 0.001, aliases: ["g", "克", "公克", "gram", "grams"]),
        .init(dimension: .mass, factor: 0.5, aliases: ["市斤"]),
        .init(dimension: .mass, factor: 0.45359237, aliases: ["lb", "lbs", "磅", "pound", "pounds"]),
        .init(dimension: .distance, factor: 1, aliases: ["m", "米", "公尺", "meter", "meters", "metre", "metres"]),
        .init(dimension: .distance, factor: 1000, aliases: ["km", "公里", "千米", "kilometer", "kilometers", "kilometre", "kilometres"]),
        .init(dimension: .distance, factor: 0.01, aliases: ["cm", "厘米", "公分"]),
        .init(dimension: .distance, factor: 0.001, aliases: ["mm", "毫米", "公釐"]),
        .init(dimension: .distance, factor: 1609.344, aliases: ["mi", "英里", "mile", "miles"]),
        .init(dimension: .duration, factor: 1, aliases: ["s", "秒", "秒钟", "秒鐘", "second", "seconds", "sec"]),
        .init(dimension: .duration, factor: 60, aliases: ["min", "分钟", "分鐘", "minute", "minutes"]),
        .init(dimension: .duration, factor: 3600, aliases: ["h", "hr", "小时", "小時", "鐘頭", "钟头", "hour", "hours"]),
        .init(dimension: .volume, factor: 1, aliases: ["ml", "毫升", "cc", "milliliter", "milliliters"]),
        .init(dimension: .volume, factor: 1000, aliases: ["l", "升", "公升", "liter", "liters", "litre", "litres"]),
        .init(dimension: .occurrence, factor: 1, aliases: ["个", "個", "次", "rep", "reps"]),
    ]

    static let quantityLabels = standards.flatMap(\.aliases) + [
        "斤", "个", "個", "次", "组", "組", "杯", "瓶", "页", "頁", "步", "支", "根", "片", "枚",
        "遍", "圈", "套", "题", "題", "章", "条", "條", "张", "張", "分", "%", "元", "块", "塊",
    ]

    static func label(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func normalized(_ raw: String?) -> String? {
        label(raw)?.precomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func standard(_ raw: String?, locale: Locale, context: String? = nil) -> Standard? {
        guard let unit = normalized(raw) else { return nil }
        let explicitMarketJin = normalized(context) == "市斤"
        let key = unit == "斤" && (locale.region?.identifier == "CN" || explicitMarketJin) ? "市斤" : unit
        return standards.first { $0.aliases.contains(key) }
    }

    static func isMass(_ raw: String?) -> Bool {
        normalized(raw) == "斤" || standard(raw, locale: Locale(identifier: "en_US_POSIX"))?.dimension == .mass
    }

    static func factor(from input: String?, to storage: String?, locale: Locale = .current) -> Double? {
        // 同名自定义单位沿用原口径。市斤的地区口径只参与不同单位的换算。
        if label(input)?.precomposedStringWithCompatibilityMapping == label(storage)?.precomposedStringWithCompatibilityMapping {
            return 1
        }
        guard let from = standard(input, locale: locale, context: storage),
              let to = standard(storage, locale: locale, context: input),
              from.dimension == to.dimension else { return nil }
        return from.factor / to.factor
    }

    /// 已保存的单位不随同步设备所在地区变化。旧数据中的裸「斤」只有同名口径可比。
    static func storedFactor(from input: String?, to storage: String?) -> Double? {
        if normalized(input) == "斤" || normalized(storage) == "斤" {
            return normalized(input) == normalized(storage) ? 1 : nil
        }
        return factor(from: input, to: storage, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func sameStorageUnit(_ old: String?, _ new: String?) -> Bool {
        storedFactor(from: old, to: new) == 1
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(FloatingPointFormatStyle<Double>()
            .locale(locale)
            .grouping(.never)
            .precision(.fractionLength(0...9)))
    }
}
