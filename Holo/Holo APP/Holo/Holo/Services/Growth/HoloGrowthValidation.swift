#if DEBUG
// 隔离验收：生产模型 + 内存库。仅显式启动参数启用，绝不接触日用数据。
import SwiftUI
import CoreData

nonisolated enum HoloGrowthValidation {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-HoloGrowthValidate") }
    static var isEmpty: Bool { ProcessInfo.processInfo.arguments.contains("-HoloGrowthEmpty") }

    static func context() throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "GrowthValidation", managedObjectModel: CoreDataStack.shared.createDataModel())
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.viewContext
    }

    @discardableResult
    static func insert(_ entity: String, into context: NSManagedObjectContext, values: [String: Any] = [:]) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        // 使用生产模型的默认值；只补齐验收样本必填的无默认标量。
        for (key, attribute) in row.entity.attributesByName where !attribute.isOptional && row.value(forKey: key) == nil {
            switch attribute.attributeType {
            case .UUIDAttributeType: row.setValue(UUID(), forKey: key)
            case .dateAttributeType: row.setValue(Date(), forKey: key)
            case .stringAttributeType: row.setValue("", forKey: key)
            case .booleanAttributeType: row.setValue(false, forKey: key)
            case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType, .doubleAttributeType, .floatAttributeType: row.setValue(0, forKey: key)
            case .decimalAttributeType: row.setValue(NSDecimalNumber(value: 1), forKey: key)
            default: break
            }
        }
        if row.entity.attributesByName["id"] != nil { row.setValue(UUID(), forKey: "id") }
        for (key, value) in values { row.setValue(value, forKey: key) }
        return row
    }

    static func seed(_ context: NSManagedObjectContext, now: Date) throws {
        let cal = Calendar.current
        for offset in 0..<68 {
            let date = cal.date(byAdding: .day, value: -offset, to: now)!
            insert("Transaction", into: context, values: ["type": "expense", "date": date, "createdAt": date])
        }
        for offset in 0..<126 {
            let date = cal.date(byAdding: .day, value: -(offset % 86), to: now)!
            insert("Thought", into: context, values: ["content": "验收想法", "createdAt": date])
        }
        let habitID = UUID()
        insert("Habit", into: context, values: ["id": habitID, "name": "阅读", "type": HabitType.checkIn.rawValue])
        for offset in 0..<42 {
            let date = cal.date(byAdding: .day, value: -offset * 2, to: now)!
            insert("HabitRecord", into: context, values: ["habitId": habitID, "date": date, "createdAt": date, "isCompleted": true])
        }
        try context.save()
    }

    static func verify(now: Date) throws -> Int {
        let ctx = try context()
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw NSError(domain: "GrowthValidation", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try seed(ctx, now: now)
        var result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.finance).count == 68, "财务天数全量聚合")
        try expect(result.snapshot.value(.thought).count == 126, "想法条数全量聚合")
        try expect(result.snapshot.value(.habit).count == 42, "习惯归属日聚合")
        try expect(result.snapshot.recordedDays == 86, "跨模块日期并集")
        let originalThought = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Thought"))[0]
        let duplicate = insert("Thought", into: ctx, values: ["id": originalThought.value(forKey: "id")!, "content": "同步副本", "createdAt": now])
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.thought).count == 126, "同步副本不重复计数")
        ctx.delete(duplicate)
        let originalHabit = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Habit"))[0]
        let cancelled = insert("HabitRecord", into: ctx, values: ["habitId": originalHabit.value(forKey: "id")!, "date": now, "createdAt": now, "isCompleted": false])
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.habit).count == 41, "撤销当前日打卡扣回天数")
        ctx.delete(cancelled)
        for (type, bad) in [(HabitType.checkIn.rawValue, true), (HabitType.numeric.rawValue, false)] {
            let habitID = UUID()
            insert("Habit", into: ctx, values: ["id": habitID, "type": type, "isBadHabit": bad])
            insert("HabitRecord", into: ctx, values: ["habitId": habitID, "date": Calendar.current.date(byAdding: .day, value: -101, to: now)!, "isCompleted": true])
        }
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.habit).count == 42, "坏习惯发生与数值记录不冒充正向打卡")
        if ctx.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Habit"]?.attributesByName["dayEndHour"] != nil {
            let shiftedID = UUID()
            let day = Calendar.current.startOfDay(for: now)
            let raw = day.addingTimeInterval(-2 * 86400 + 3600)
            let shifted = Calendar.current.startOfDay(for: raw.addingTimeInterval(-4 * 3600))
            let customHabit = insert("Habit", into: ctx, values: ["id": shiftedID, "type": HabitType.checkIn.rawValue, "dayEndHour": 4])
            let shiftedRecord = insert("HabitRecord", into: ctx, values: ["habitId": shiftedID, "date": raw, "createdAt": raw, "isCompleted": true])
            try ctx.save()
            result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
            try expect(result.snapshot.value(.habit).dates.contains(shifted), "自定义结算时间按归属日计入")
            ctx.delete(shiftedRecord)
            ctx.delete(customHabit)
            try ctx.save()
            result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        }
        let baselineCount = result.events.count
        try expect(baselineCount == 10, "三系列各档历史初始化")
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.events.count == baselineCount, "重复加载不重复颁发")
        let habits = [originalHabit]
        habits[0].setValue(true, forKey: "isArchived")
        let thoughts = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Thought"))
        thoughts[0].setValue(true, forKey: "isArchived")
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.habit).count == 42, "归档习惯保留付出")
        try expect(result.snapshot.value(.thought).count == 126, "归档想法保留付出")
        habits[0].setValue(now, forKey: "deletedAt")
        thoughts[0].setValue(now, forKey: "deletedAt")
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.habit).count == 0, "父习惯删除后不读悬空记录")
        try expect(result.snapshot.value(.thought).count == 125, "删除想法降低当前计数")
        try expect(result.events.count == baselineCount, "删除不抹掉历史成就")
        habits[0].setValue(nil, forKey: "deletedAt")
        thoughts[0].setValue(nil, forKey: "deletedAt")
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.habit).count == 42 && result.snapshot.value(.thought).count == 126, "恢复后重新计入")
        let older = Calendar.current.date(byAdding: .day, value: -100, to: now)!
        insert("Transaction", into: ctx, values: ["type": "expense", "date": older, "isReconciliationAdjustment": true])
        insert("Transaction", into: ctx, values: ["type": "transfer", "date": older])
        insert("Transaction", into: ctx, values: ["type": "expense", "date": Calendar.current.date(byAdding: .day, value: 1, to: now)!])
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.finance).count == 68, "调整、转账和未来交易不计入")
        let account = insert("Account", into: ctx, values: ["deletedAt": now])
        insert("Transaction", into: ctx, values: ["type": "expense", "date": older, "account": account])
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.finance).count == 68, "父账户删除后不读子交易")
        account.setValue(nil, forKey: "deletedAt")
        account.setValue(true, forKey: "isArchived")
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.value(.finance).count == 69, "归档账户的历史收支计入")
        try HoloGrowthStore.setReminders(false, context: ctx)
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(!result.remindersEnabled, "提醒设置持久化")
        for name in ["Habit", "Thought", "Transaction"] {
            for row in try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) { row.setValue(now, forKey: "deletedAt") }
        }
        try HoloGrowthStore.clear(context: ctx)
        try ctx.save()
        result = try HoloGrowthStore.load(context: ctx, now: now, persist: true)
        try expect(result.snapshot.recordedDays == 0 && result.events.isEmpty, "全量清空同时清除成就")
        try expect(result.remindersEnabled, "全量清空同时清除提醒偏好")
        insert("UserPreferenceEntity", into: ctx, values: ["key": HoloGrowthStore.eventPrefix + "v1.invalid", "value": "broken"])
        try ctx.save()
        var caught = false
        do { _ = try HoloGrowthStore.load(context: ctx, now: now, persist: true) } catch { caught = true }
        try expect(caught, "存储解析失败不能伪装成零积累")
        return checks
    }
}

struct HoloGrowthValidationView: View {
    @State private var service: HoloGrowthService?
    @State private var report = "正在执行隔离验收"
    var body: some View {
        VStack(spacing: 0) {
            Text(report).font(.caption).padding(8).accessibilityIdentifier("growth.validation.result")
            if let service {
                NavigationStack { HoloGrowthView(service: service, onOpenModule: { _ in }) }
            }
        }
        .task {
            do {
                let now = Date()
                let checks = try HoloGrowthValidation.verify(now: now)
                let context = try HoloGrowthValidation.context()
                if !HoloGrowthValidation.isEmpty { try HoloGrowthValidation.seed(context, now: now) }
                let fixtureService = HoloGrowthService(validationContext: context)
                fixtureService.setValidationDownloading(true)
                await fixtureService.refresh()
                guard fixtureService.snapshot != nil, fixtureService.milestones.isEmpty else {
                    throw NSError(domain: "GrowthValidation", code: 27, userInfo: [NSLocalizedDescriptionKey: "同步期间应展示本机统计，但不颁发里程碑"])
                }
                guard fixtureService.snapshot?.recordedDays == (HoloGrowthValidation.isEmpty ? 0 : 86) else {
                    throw NSError(domain: "GrowthValidation", code: 28, userInfo: [NSLocalizedDescriptionKey: "同步状态不能阻断真实计数"])
                }
                fixtureService.setValidationDownloading(false)
                await fixtureService.refresh()
                guard fixtureService.celebration == nil else {
                    throw NSError(domain: "GrowthValidation", code: 29, userInfo: [NSLocalizedDescriptionKey: "同步收尾不能把历史积累当作新成就庆祝"])
                }
                let trustedDays = fixtureService.snapshot?.recordedDays
                let corrupt = HoloGrowthValidation.insert("UserPreferenceEntity", into: context,
                    values: ["key": HoloGrowthStore.eventPrefix + "v1.corrupt", "value": "broken"])
                try context.save()
                await fixtureService.refresh()
                guard fixtureService.snapshot?.recordedDays == trustedDays, fixtureService.errorMessage != nil else {
                    throw NSError(domain: "GrowthValidation", code: 24, userInfo: [NSLocalizedDescriptionKey: "失败应保留可信快照"])
                }
                context.delete(corrupt)
                try context.save()
                await fixtureService.refresh()
                guard fixtureService.errorMessage == nil else {
                    throw NSError(domain: "GrowthValidation", code: 25, userInfo: [NSLocalizedDescriptionKey: "重试后应恢复"])
                }
                await fixtureService.setRemindersEnabled(false)
                await fixtureService.refresh()
                guard !fixtureService.remindersEnabled else {
                    throw NSError(domain: "GrowthValidation", code: 26, userInfo: [NSLocalizedDescriptionKey: "提醒设置应保存到当前数据范围"])
                }
                await fixtureService.setRemindersEnabled(true)
                service = fixtureService
                report = "PASS · \(checks + 6) 项存储/状态验收 · 独立内存库"
                try Data(report.utf8).write(to: URL.documentsDirectory.appendingPathComponent("growth-validation.txt"))
            } catch {
                report = "FAIL · \(error.localizedDescription)"
                try? Data(report.utf8).write(to: URL.documentsDirectory.appendingPathComponent("growth-validation.txt"))
            }
        }
    }
}
#endif
