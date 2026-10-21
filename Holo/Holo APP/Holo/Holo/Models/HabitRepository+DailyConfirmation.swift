import Foundation
import CoreData

@MainActor
extension HabitRepository {
    func dailyConfirmation(for habit: Habit, on day: Date, calendar: Calendar = .current) throws -> HabitDailyConfirmationFact? {
        let request = NSFetchRequest<HabitDailyConfirmationMO>(entityName: "HabitDailyConfirmationMO")
        request.predicate = NSPredicate(format: "habitID == %@ AND day == %@", habit.id as CVarArg, calendar.startOfDay(for: day) as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "confirmedAt", ascending: false), NSSortDescriptor(key: "id", ascending: false)]
        request.fetchLimit = 1
        guard habit.deletedAt == nil, !habit.isDeleted, let row = try context.fetch(request).first,
              let status = HabitDailyConfirmationStatus(rawValue: row.statusRaw), status != .withdrawn else { return nil }
        let records = try fetchRecords(for: habit, from: day, through: day)
        let digest = HabitDailyConfirmationDigest.make(records.map { ($0.id, $0.valueDouble, $0.isCompleted) })
        return HabitDailyConfirmationFact(day: row.day, status: status,
                                         isValid: row.recordDigest == digest && row.dayEndMinutes == habit.dayEndMinutes && row.timeZoneID == calendar.timeZone.identifier)
    }

    /// 隔离 context 一次提交。只撤回确认，不删除数量；符合/没做到仍以原打卡记录为准。
    func confirmDay(habitID: UUID, day: Date, status: HabitDailyConfirmationStatus, now: Date = Date()) throws {
        guard let habit = findHabit(by: habitID), !habit.isArchived, !habit.isPaused else {
            throw HabitError.invalidData
        }
        let calendar = Calendar.current, day = calendar.startOfDay(for: day)
        let today = habit.currentDay(now: now, calendar: calendar)
        let existing = try dailyConfirmation(for: habit, on: day)
        let earliest = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        guard day <= today, day >= habit.creationDay(calendar: calendar),
              day >= earliest || existing != nil, !habit.isDayPaused(day, calendar: calendar) else { throw HabitError.invalidData }
        if status == .withdrawn, existing == nil { return }
        if let existing, existing.isValid, existing.status == status { return }
        let dayRecords = try fetchRecords(for: habit, from: day, through: day)
        if status == .asOf, day != today { throw HabitError.invalidData }
        if status == .notMet, day == today { throw HabitError.invalidData }
        if status == .none, day == today { throw HabitError.invalidData }
        if status == .none, dayRecords.contains(where: { ($0.valueDouble ?? 0) > 0 || (habit.isCheckInType && $0.isCompleted) }) { throw HabitError.invalidData }
        if status == .met, !dayRecords.contains(where: \.isCompleted) { throw HabitError.invalidData }
        if status == .notMet, dayRecords.contains(where: \.isCompleted) { throw HabitError.invalidData }
        if habit.isCheckInType && !habit.isBadHabit {
            guard [.met, .notMet, .withdrawn].contains(status) else { throw HabitError.invalidData }
        } else {
            guard !habit.isMeasureType, [.complete, .none, .asOf, .withdrawn].contains(status),
                  day != today || status == .asOf || status == .withdrawn else { throw HabitError.invalidData }
        }
        let isolated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        isolated.persistentStoreCoordinator = context.persistentStoreCoordinator
        guard let parent = try isolated.existingObject(with: habit.objectID) as? Habit else { throw HabitError.notFound }
        let row = HabitDailyConfirmationMO(context: isolated)
        row.id = UUID(); row.habitID = habitID; row.habit = parent; row.day = day
        row.confirmedAt = now; row.statusRaw = status.rawValue
        row.recordDigest = HabitDailyConfirmationDigest.make(dayRecords.map { ($0.id, $0.valueDouble, $0.isCompleted) })
        row.timeZoneID = calendar.timeZone.identifier; row.dayEndMinutes = Int16(habit.dayEndMinutes)
        try isolated.save()
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSInsertedObjectsKey: [row.objectID], NSUpdatedObjectsKey: [parent.objectID]], into: [context])
        notifyDataChange(habitId: habitID)
    }
}
