//
//  CoreDataStack+HabitEntities.swift
//  Holo
//
//  习惯相关 Core Data 实体定义
//

import CoreData
import CryptoKit

extension CoreDataStack {

    // MARK: - Habit Entities

    /// 创建习惯相关实体（Habit, HabitRecord）
    nonisolated func createHabitEntities(goalEntity: NSEntityDescription) -> [NSEntityDescription] {
        // MARK: - Habit Entity
        // 习惯实体，支持打卡型和数值型两种习惯
        let habitEntity = NSEntityDescription()
        habitEntity.name = "Habit"
        habitEntity.managedObjectClassName = "Habit"
        
        var habitAttributes: [NSAttributeDescription] = []
        
        // 习惯唯一标识符
        let habitId = NSAttributeDescription()
        habitId.name = "id"
        habitId.attributeType = .UUIDAttributeType
        habitId.isOptional = false
        habitId.defaultValue = UUID()
        habitAttributes.append(habitId)
        
        // 习惯名称
        let habitName = NSAttributeDescription()
        habitName.name = "name"
        habitName.attributeType = .stringAttributeType
        habitName.isOptional = false
        habitName.defaultValue = ""
        habitAttributes.append(habitName)
        
        // SF Symbol 图标名称
        let habitIcon = NSAttributeDescription()
        habitIcon.name = "icon"
        habitIcon.attributeType = .stringAttributeType
        habitIcon.isOptional = false
        habitIcon.defaultValue = "checkmark.circle"
        habitAttributes.append(habitIcon)
        
        // Hex 颜色值
        let habitColor = NSAttributeDescription()
        habitColor.name = "color"
        habitColor.attributeType = .stringAttributeType
        habitColor.isOptional = false
        habitColor.defaultValue = "#5B8CFF"
        habitAttributes.append(habitColor)
        
        // 习惯类型：0=打卡型, 1=数值型
        let habitType = NSAttributeDescription()
        habitType.name = "type"
        habitType.attributeType = .integer16AttributeType
        habitType.isOptional = false
        habitType.defaultValue = 0
        habitAttributes.append(habitType)
        
        // 频率：daily/weekly/monthly
        let habitFrequency = NSAttributeDescription()
        habitFrequency.name = "frequency"
        habitFrequency.attributeType = .stringAttributeType
        habitFrequency.isOptional = false
        habitFrequency.defaultValue = "daily"
        habitAttributes.append(habitFrequency)
        
        // 打卡型目标次数（如每周 5 次）
        let habitTargetCount = NSAttributeDescription()
        habitTargetCount.name = "targetCount"
        habitTargetCount.attributeType = .integer16AttributeType
        habitTargetCount.isOptional = true
        habitAttributes.append(habitTargetCount)
        
        // 数值型目标值（如体重 65 kg）
        let habitTargetValue = NSAttributeDescription()
        habitTargetValue.name = "targetValue"
        habitTargetValue.attributeType = .doubleAttributeType
        habitTargetValue.isOptional = true
        habitAttributes.append(habitTargetValue)
        
        // 数值型单位（如 kg, 次, 杯）
        let habitUnit = NSAttributeDescription()
        habitUnit.name = "unit"
        habitUnit.attributeType = .stringAttributeType
        habitUnit.isOptional = true
        habitAttributes.append(habitUnit)
        
        // 聚合类型：0=SUM(计数类，如抽烟次数), 1=LATEST(测量类，如体重)
        let habitAggregationType = NSAttributeDescription()
        habitAggregationType.name = "aggregationType"
        habitAggregationType.attributeType = .integer16AttributeType
        habitAggregationType.isOptional = false
        habitAggregationType.defaultValue = 0
        habitAttributes.append(habitAggregationType)
        
        // 是否为坏习惯（如抽烟、熬夜）
        let habitIsBadHabit = NSAttributeDescription()
        habitIsBadHabit.name = "isBadHabit"
        habitIsBadHabit.attributeType = .booleanAttributeType
        habitIsBadHabit.isOptional = false
        habitIsBadHabit.defaultValue = false
        habitAttributes.append(habitIsBadHabit)

        // 是否已归档
        let habitIsArchived = NSAttributeDescription()
        habitIsArchived.name = "isArchived"
        habitIsArchived.attributeType = .booleanAttributeType
        habitIsArchived.isOptional = false
        habitIsArchived.defaultValue = false
        habitAttributes.append(habitIsArchived)

        // 是否暂停中（暂时无法执行；连续天数冻结，详见 HabitPauseWindow）
        let habitIsPaused = NSAttributeDescription()
        habitIsPaused.name = "isPaused"
        habitIsPaused.attributeType = .booleanAttributeType
        habitIsPaused.isOptional = false
        habitIsPaused.defaultValue = false
        habitAttributes.append(habitIsPaused)

        // 计划恢复日（可选；到日后打开 App 自动恢复）
        let habitPausedUntil = NSAttributeDescription()
        habitPausedUntil.name = "pausedUntil"
        habitPausedUntil.attributeType = .dateAttributeType
        habitPausedUntil.isOptional = true
        habitAttributes.append(habitPausedUntil)

        // 历次暂停窗口（[HabitPauseWindow] 的 Codable 编码）
        let habitPauseWindowsData = NSAttributeDescription()
        habitPauseWindowsData.name = "pauseWindowsData"
        habitPauseWindowsData.attributeType = .binaryDataAttributeType
        habitPauseWindowsData.isOptional = true
        habitAttributes.append(habitPauseWindowsData)
        
        // 排序顺序
        let habitSortOrder = NSAttributeDescription()
        habitSortOrder.name = "sortOrder"
        habitSortOrder.attributeType = .integer16AttributeType
        habitSortOrder.isOptional = false
        habitSortOrder.defaultValue = 0
        habitAttributes.append(habitSortOrder)

        // 打卡提醒模式：follow=跟随兜底提醒, solo=单独时间, none=不提醒（仅打卡型参与提醒）
        let habitReminderMode = NSAttributeDescription()
        habitReminderMode.name = "reminderMode"
        habitReminderMode.attributeType = .stringAttributeType
        habitReminderMode.isOptional = false
        habitReminderMode.defaultValue = "follow"
        habitAttributes.append(habitReminderMode)

        // 单独提醒时间（solo 模式使用，默认 09:00）
        let habitReminderHour = NSAttributeDescription()
        habitReminderHour.name = "reminderHour"
        habitReminderHour.attributeType = .integer16AttributeType
        habitReminderHour.isOptional = false
        habitReminderHour.defaultValue = 9
        habitAttributes.append(habitReminderHour)

        let habitReminderMinute = NSAttributeDescription()
        habitReminderMinute.name = "reminderMinute"
        habitReminderMinute.attributeType = .integer16AttributeType
        habitReminderMinute.isOptional = false
        habitReminderMinute.defaultValue = 0
        habitAttributes.append(habitReminderMinute)

        // 每日结算时间（距零点的时/分，默认 0:00 = 自然日；结算前的打卡归前一天，见 HabitDayAttribution）
        let habitDayEndHour = NSAttributeDescription()
        habitDayEndHour.name = "dayEndHour"
        habitDayEndHour.attributeType = .integer16AttributeType
        habitDayEndHour.isOptional = false
        habitDayEndHour.defaultValue = 0
        habitAttributes.append(habitDayEndHour)

        let habitDayEndMinute = NSAttributeDescription()
        habitDayEndMinute.name = "dayEndMinute"
        habitDayEndMinute.attributeType = .integer16AttributeType
        habitDayEndMinute.isOptional = false
        habitDayEndMinute.defaultValue = 0
        habitAttributes.append(habitDayEndMinute)
        
        // 创建时间
        let habitCreatedAt = NSAttributeDescription()
        habitCreatedAt.name = "createdAt"
        habitCreatedAt.attributeType = .dateAttributeType
        habitCreatedAt.isOptional = false
        habitCreatedAt.defaultValue = Date()
        habitAttributes.append(habitCreatedAt)
        
        // 更新时间
        let habitUpdatedAt = NSAttributeDescription()
        habitUpdatedAt.name = "updatedAt"
        habitUpdatedAt.attributeType = .dateAttributeType
        habitUpdatedAt.isOptional = false
        habitUpdatedAt.defaultValue = Date()
        habitAttributes.append(habitUpdatedAt)
        
        // MARK: - HabitRecord Entity
        // 习惯记录实体，支持一天多次记录
        let habitRecordEntity = NSEntityDescription()
        habitRecordEntity.name = "HabitRecord"
        habitRecordEntity.managedObjectClassName = "HabitRecord"
        
        var habitRecordAttributes: [NSAttributeDescription] = []
        
        // 记录唯一标识符
        let recordId = NSAttributeDescription()
        recordId.name = "id"
        recordId.attributeType = .UUIDAttributeType
        recordId.isOptional = false
        recordId.defaultValue = UUID()
        habitRecordAttributes.append(recordId)
        
        // 关联的习惯 ID（用于查询，关系由 relationship 维护）
        let recordHabitId = NSAttributeDescription()
        recordHabitId.name = "habitId"
        recordHabitId.attributeType = .UUIDAttributeType
        recordHabitId.isOptional = false
        recordHabitId.defaultValue = UUID()
        habitRecordAttributes.append(recordHabitId)
        
        // 记录时间（精确到秒，支持一天多次记录）
        let recordDate = NSAttributeDescription()
        recordDate.name = "date"
        recordDate.attributeType = .dateAttributeType
        recordDate.isOptional = false
        recordDate.defaultValue = Date()
        habitRecordAttributes.append(recordDate)
        
        // 打卡型完成状态
        let recordIsCompleted = NSAttributeDescription()
        recordIsCompleted.name = "isCompleted"
        recordIsCompleted.attributeType = .booleanAttributeType
        recordIsCompleted.isOptional = false
        recordIsCompleted.defaultValue = false
        habitRecordAttributes.append(recordIsCompleted)
        
        // 数值型记录值
        let recordValue = NSAttributeDescription()
        recordValue.name = "value"
        recordValue.attributeType = .doubleAttributeType
        recordValue.isOptional = true
        habitRecordAttributes.append(recordValue)
        
        // 备注
        let recordNote = NSAttributeDescription()
        recordNote.name = "note"
        recordNote.attributeType = .stringAttributeType
        recordNote.isOptional = true
        habitRecordAttributes.append(recordNote)

        // 补签标记（补签写入的历史记录与当日实时打卡如实区分）
        let recordIsRetroactive = NSAttributeDescription()
        recordIsRetroactive.name = "isRetroactive"
        recordIsRetroactive.attributeType = .booleanAttributeType
        recordIsRetroactive.isOptional = false
        recordIsRetroactive.defaultValue = false
        habitRecordAttributes.append(recordIsRetroactive)
        
        // 创建时间
        let recordCreatedAt = NSAttributeDescription()
        recordCreatedAt.name = "createdAt"
        recordCreatedAt.attributeType = .dateAttributeType
        recordCreatedAt.isOptional = false
        recordCreatedAt.defaultValue = Date()
        habitRecordAttributes.append(recordCreatedAt)
        
        // MARK: - Habit ↔ HabitRecord 关系定义
        // Habit.records: 一对多关系，删除习惯时级联删除所有记录
        let habitRecordsRelation = NSRelationshipDescription()
        habitRecordsRelation.name = "records"
        habitRecordsRelation.destinationEntity = habitRecordEntity
        habitRecordsRelation.minCount = 0
        habitRecordsRelation.maxCount = 0  // 0 表示无上限（to-many）
        habitRecordsRelation.deleteRule = .cascadeDeleteRule
        habitRecordsRelation.isOptional = true
        
        // HabitRecord.habit: 多对一关系
        let recordHabitRelation = NSRelationshipDescription()
        recordHabitRelation.name = "habit"
        recordHabitRelation.destinationEntity = habitEntity
        recordHabitRelation.minCount = 0
        recordHabitRelation.maxCount = 1
        recordHabitRelation.deleteRule = .nullifyDeleteRule
        recordHabitRelation.isOptional = true
        
        // 设置双向关系
        habitRecordsRelation.inverseRelationship = recordHabitRelation
        recordHabitRelation.inverseRelationship = habitRecordsRelation
        
        // Goal ↔ Habit 关系
        let goalHabitsRelation = NSRelationshipDescription()
        goalHabitsRelation.name = "habits"
        goalHabitsRelation.destinationEntity = habitEntity
        goalHabitsRelation.minCount = 0
        goalHabitsRelation.maxCount = 0
        goalHabitsRelation.deleteRule = .nullifyDeleteRule
        goalHabitsRelation.isOptional = true

        let habitGoalRelation = NSRelationshipDescription()
        habitGoalRelation.name = "goal"
        habitGoalRelation.destinationEntity = goalEntity
        habitGoalRelation.minCount = 0
        habitGoalRelation.maxCount = 1
        habitGoalRelation.deleteRule = .nullifyDeleteRule
        habitGoalRelation.isOptional = true

        goalHabitsRelation.inverseRelationship = habitGoalRelation
        habitGoalRelation.inverseRelationship = goalHabitsRelation

        goalEntity.properties.append(goalHabitsRelation)
        let habitSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        habitAttributes.append(contentsOf: habitSoftDelete.attributes)
        let recordSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        habitRecordAttributes.append(contentsOf: recordSoftDelete.attributes)

        habitEntity.properties = habitAttributes + [habitRecordsRelation, habitGoalRelation]
        CoreDataStack.applyIndexes(to: habitEntity, on: ["id": habitId, "type": habitType, "isArchived": habitIsArchived, "sortOrder": habitSortOrder, "deletedAt": habitSoftDelete.deletedAt, "deletedBatchId": habitSoftDelete.deletedBatchId])
        habitRecordEntity.properties = habitRecordAttributes + [recordHabitRelation]
        CoreDataStack.applyIndexes(to: habitRecordEntity, on: ["id": recordId, "habitId": recordHabitId, "date": recordDate, "deletedAt": recordSoftDelete.deletedAt, "deletedBatchId": recordSoftDelete.deletedBatchId])

        let confirmationEntity = createHabitDailyConfirmationEntity(habitEntity: habitEntity)
        return [habitEntity, habitRecordEntity, confirmationEntity]
    }

}


enum HabitDailyConfirmationStatus: String, Codable, CaseIterable {
    case complete, none, asOf, met, notMet, withdrawn

    var title: String {
        switch self {
        case .complete: return "这一天的记录已齐全"
        case .none: return "这一天确认未发生"
        case .asOf: return "截至现在已核对，今天仍在进行"
        case .met: return "这一天明确做到了"
        case .notMet: return "这一天明确没做到"
        case .withdrawn: return "待确认"
        }
    }
}

/// 日确认是原记录的完整性声明，不作为一笔可累计数量。
@objc(HabitDailyConfirmationMO)
final class HabitDailyConfirmationMO: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var habitID: UUID
    @NSManaged var day: Date
    @NSManaged var confirmedAt: Date
    @NSManaged var statusRaw: String
    @NSManaged var recordDigest: String
    @NSManaged var timeZoneID: String
    @NSManaged var dayEndMinutes: Int16
    @NSManaged var habit: Habit?
}

struct HabitDailyConfirmationFact: Equatable {
    var day: Date
    var status: HabitDailyConfirmationStatus
    var isValid: Bool
}

enum HabitDailyConfirmationDigest {
    static func make(_ values: [(UUID, Double?, Bool)]) -> String {
        let text = values.sorted { $0.0.uuidString < $1.0.uuidString }
            .map { "\($0.0.uuidString)|\($0.1.map(String.init(describing:)) ?? "nil")|\($0.2)" }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension CoreDataStack {
    nonisolated func createHabitDailyConfirmationEntity(habitEntity: NSEntityDescription) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HabitDailyConfirmationMO"
        entity.managedObjectClassName = NSStringFromClass(HabitDailyConfirmationMO.self)
        let fields: [(String, NSAttributeType, Any)] = [
            ("id", .UUIDAttributeType, UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))),
            ("habitID", .UUIDAttributeType, UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))),
            ("day", .dateAttributeType, Date(timeIntervalSince1970: 0)),
            ("confirmedAt", .dateAttributeType, Date(timeIntervalSince1970: 0)),
            ("statusRaw", .stringAttributeType, "withdrawn"),
            ("recordDigest", .stringAttributeType, ""),
            ("timeZoneID", .stringAttributeType, ""),
            ("dayEndMinutes", .integer16AttributeType, 0)
        ]
        entity.properties = fields.map { name, type, value in
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type
            a.isOptional = false; a.defaultValue = value; return a
        }
        let parent = NSRelationshipDescription()
        parent.name = "habit"; parent.destinationEntity = habitEntity
        parent.maxCount = 1; parent.isOptional = true; parent.deleteRule = .nullifyDeleteRule
        let children = NSRelationshipDescription()
        children.name = "dailyConfirmations"; children.destinationEntity = entity
        children.maxCount = 0; children.isOptional = true; children.deleteRule = .cascadeDeleteRule
        parent.inverseRelationship = children; children.inverseRelationship = parent
        entity.properties.append(parent); habitEntity.properties.append(children)
        return entity
    }
}
