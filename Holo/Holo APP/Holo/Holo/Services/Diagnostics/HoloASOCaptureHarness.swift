#if DEBUG && targetEnvironment(simulator)
import CoreData
import Foundation

/// 宣传图专用的隔离数据入口；仅在模拟器及显式启动参数下工作。
@MainActor
enum HoloASOCaptureHarness {
    private struct Fixture: Decodable {
        let fixtureInstanceID: String
        let referenceDate: String
        let habits: [HabitFixture]

        enum CodingKeys: String, CodingKey {
            case fixtureInstanceID = "fixture_instance_id"
            case referenceDate = "reference_date"
            case habits
        }
    }

    private struct HabitFixture: Decodable {
        struct Entry: Decodable {
            let date: String
            let value: Double
        }
        let id: String
        let seedDates: [String]?
        let entries: [Entry]?
        enum CodingKeys: String, CodingKey {
            case id, entries
            case seedDates = "seed_dates"
        }
    }

    static func seedHabitsIfRequested(environment: [String: String]) throws -> Bool {
        guard environment["HOLO_ASO_V10"] == "1", environment["HOLO_ASO_SEED"] == "1" else { return false }
        guard !CloudKitRuntimeAvailability.isAvailable else {
            throw NSError(domain: "HoloASO", code: 1, userInfo: [NSLocalizedDescriptionKey: "演示环境不能连接 CloudKit"])
        }
        let file = URL.documentsDirectory.appendingPathComponent("aso-fixture.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard fixture.referenceDate == formatter.string(from: Date()),
              let walk = fixture.habits.first(where: { $0.id == "H-WALK" }),
              let dates = walk.seedDates, dates.count == 36,
              let reading = fixture.habits.first(where: { $0.id == "H-READ" }),
              let entries = reading.entries, entries.count == 18,
              entries.reduce(0, { $0 + $1.value }) == 600 else {
            throw NSError(domain: "HoloASO", code: 2, userInfo: [NSLocalizedDescriptionKey: "演示日期或习惯数据不匹配"])
        }
        let defaults = UserDefaults.standard
        let key = "holo_aso_v10_habits_" + fixture.fixtureInstanceID
        guard !defaults.bool(forKey: key) else { return true }
        let context = CoreDataStack.shared.viewContext
        guard !context.hasChanges else {
            throw NSError(domain: "HoloASO", code: 3, userInfo: [NSLocalizedDescriptionKey: "数据库存在未保存的其他修改"])
        }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "name IN %@ AND deletedAt == nil", ["散步", "阅读"])
        guard try context.count(for: request) == 0 else {
            throw NSError(domain: "HoloASO", code: 4, userInfo: [NSLocalizedDescriptionKey: "演示习惯名称已存在，停止写入"])
        }
        let walkHabit = Habit.create(in: context, name: "散步", icon: "figure.walk", color: "#66856D", type: .checkIn, targetCount: 1)
        let readingHabit = Habit.create(in: context, name: "阅读", icon: "book.fill", color: "#81708D", type: .numeric, targetValue: 30, unit: "分钟", sortOrder: 1)
        guard let earliest = dates.compactMap({ formatter.date(from: $0) }).min() else {
            context.rollback()
            throw NSError(domain: "HoloASO", code: 5, userInfo: [NSLocalizedDescriptionKey: "习惯日期无法解析"])
        }
        walkHabit.createdAt = earliest.addingTimeInterval(-86400)
        readingHabit.createdAt = earliest.addingTimeInterval(-86400)
        do {
            for value in dates {
                guard let day = formatter.date(from: value) else { throw NSError(domain: "HoloASO", code: 6) }
                let record = HabitRecord.createCheckIn(in: context, habit: walkHabit)
                record.date = day.addingTimeInterval(12 * 3600)
                record.createdAt = record.date
            }
            for entry in entries {
                guard let day = formatter.date(from: entry.date) else { throw NSError(domain: "HoloASO", code: 7) }
                let record = HabitRecord.createNumeric(in: context, habit: readingHabit, value: entry.value)
                record.date = day.addingTimeInterval(12 * 3600)
                record.createdAt = record.date
            }
            try context.save()
            defaults.set(true, forKey: key)
            NotificationCenter.default.post(name: .habitDataDidChange, object: nil)
            print("[HoloASO] 习惯演示记录已保存：散步36条，阅读18条；实例 \(fixture.fixtureInstanceID)")
            return true
        } catch {
            context.rollback()
            throw error
        }
    }
}
#endif
