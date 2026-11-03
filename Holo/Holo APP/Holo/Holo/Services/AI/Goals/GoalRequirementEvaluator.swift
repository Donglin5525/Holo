import Foundation
import CoreData
import CryptoKit

@MainActor
enum GoalRequirementEvaluator {
    static func evaluate(binding: GoalPlanBindingV2, repository: HabitRepository,
                         context: NSManagedObjectContext, cutoff: Date, calendar: Calendar = .current) throws -> GoalRequirementObservation? {
        guard let rule = binding.requirement else { return nil }
        let habit = binding.entityType == .habit ? binding.entityID.flatMap { repository.findHabit(by: $0) } : nil
        let today = habit?.currentDay(now: cutoff, calendar: calendar) ?? calendar.startOfDay(for: cutoff)
        let end = rule.closedDaysOnly ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? cutoff
        let start = rule.calendarMonth ? (calendar.dateInterval(of: .month, for: today)?.start ?? today)
            : calendar.date(byAdding: .day, value: -max(rule.windowDays, 1), to: end) ?? today
        var result = GoalRequirementObservation(id: binding.id, title: binding.displayTitle ?? "目标条件", entityID: binding.entityID,
            entityType: binding.entityType, role: binding.role, requirement: rule, value: nil, unit: "",
            windowStart: start, windowEndExclusive: end, confirmedDays: 0,
            expectedDays: max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 1), state: .missing, sourceDigest: "")
        result.recordNotBefore = binding.effectiveFrom
        guard let id = binding.entityID else { result.state = .unavailable; return result }
        if binding.entityType == .task {
            let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
            guard let task = try context.fetch(request).first else { result.state = .unavailable; return result }
            result.title = task.title; result.value = task.completed ? 1 : 0; result.unit = "项"
            result.sourceDigest = "\(task.id)|\(task.completed)|\(task.updatedAt)"
        } else if binding.entityType == .habit {
            guard let habit, !habit.isArchived else { result.state = .unavailable; return result }
            result.title = habit.name
            let records = try repository.fetchRecords(for: habit, from: start, through: end.addingTimeInterval(-1)).filter {
                ($0.isRetroactive || $0.date < cutoff) && $0.date >= (binding.effectiveFrom ?? .distantPast)
            }
            let completed = records.filter(\.isCompleted)
            let values = records.compactMap(\.valueDouble).filter(\.isFinite)
            var day = start, confirmationParts: [String] = []
            while day < end {
                if let fact = try repository.dailyConfirmation(for: habit, on: day), fact.isValid {
                    if fact.status != .asOf { result.confirmedDays += 1 }
                    confirmationParts.append("\(day)|\(fact.status.rawValue)")
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }; day = next
            }
            let hasConfirmedObservation = !confirmationParts.isEmpty
            switch rule.metric {
            case .recordedDays:
                let eligible = habit.isCheckInType ? completed : records
                result.value = eligible.isEmpty && !hasConfirmedObservation ? nil : Double(Set(eligible.map { $0.attributedDay(dayEndMinutes: habit.dayEndMinutes, calendar: calendar) }).count)
                result.unit = "天"
            case .eventCount:
                result.value = (habit.isCheckInType ? completed.isEmpty : records.isEmpty) && !hasConfirmedObservation ? nil : Double(habit.isCheckInType ? completed.count : records.count); result.unit = "次"
            case .sum:
                result.value = values.isEmpty && !hasConfirmedObservation ? nil : values.reduce(0, +); result.unit = habit.unit ?? ""
            case .latest:
                result.value = records.sorted { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }.first(where: { $0.valueDouble != nil })?.valueDouble
                result.unit = habit.unit ?? ""
            case .taskCompletion: result.state = .unavailable; return result
            }
            let basis = HabitDailyConfirmationDigest.make(records.map { ($0.id, $0.valueDouble, $0.isCompleted) }) + confirmationParts.joined() + records.map { $0.note ?? "" }.joined(separator: "|")
            result.sourceDigest = SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined()
        } else { result.state = .unavailable; return result }
        if let value = result.value {
            if rule.comparison == .stayBelow {
                let ended = (!rule.calendarMonth && rule.closedDaysOnly) || (rule.calendarMonth && (calendar.dateInterval(of: .month, for: start)?.end ?? cutoff) <= cutoff)
                result.state = value > rule.target ? .unmet : rule.metric == .latest || (ended && result.confirmedDays >= result.expectedDays) ? .met : .observing
            } else { result.state = value >= rule.target ? .met : .unmet }
        }
        return result
    }
}
