//
//  CoreDataStack+GoalEntities.swift
//  Holo
//
//  目标相关 Core Data 实体定义
//

import Foundation
import CoreData

extension CoreDataStack {
    nonisolated func createGoalEntity() -> NSEntityDescription {
        let goalEntity = NSEntityDescription()
        goalEntity.name = "Goal"
        goalEntity.managedObjectClassName = "Goal"

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = false
        title.defaultValue = ""

        let summary = NSAttributeDescription()
        summary.name = "summary"
        summary.attributeType = .stringAttributeType
        summary.isOptional = true

        let domain = NSAttributeDescription()
        domain.name = "domain"
        domain.attributeType = .stringAttributeType
        domain.isOptional = false
        domain.defaultValue = GoalDomain.other.rawValue

        let iconEmoji = NSAttributeDescription()
        iconEmoji.name = "iconEmoji"
        iconEmoji.attributeType = .stringAttributeType
        iconEmoji.isOptional = true

        let desiredOutcome = NSAttributeDescription()
        desiredOutcome.name = "desiredOutcome"
        desiredOutcome.attributeType = .stringAttributeType
        desiredOutcome.isOptional = true

        let motivation = NSAttributeDescription()
        motivation.name = "motivation"
        motivation.attributeType = .stringAttributeType
        motivation.isOptional = true

        let status = NSAttributeDescription()
        status.name = "status"
        status.attributeType = .stringAttributeType
        status.isOptional = false
        status.defaultValue = GoalStatus.active.rawValue

        let deadline = NSAttributeDescription()
        deadline.name = "deadline"
        deadline.attributeType = .dateAttributeType
        deadline.isOptional = true

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()

        let completedAt = NSAttributeDescription()
        completedAt.name = "completedAt"
        completedAt.attributeType = .dateAttributeType
        completedAt.isOptional = true

        let source = NSAttributeDescription()
        source.name = "source"
        source.attributeType = .stringAttributeType
        source.isOptional = false
        source.defaultValue = "holoAI"

        let allowAIContext = NSAttributeDescription()
        allowAIContext.name = "allowAIContext"
        allowAIContext.attributeType = .booleanAttributeType
        allowAIContext.isOptional = false
        allowAIContext.defaultValue = false

        let proactiveNudge = NSAttributeDescription()
        proactiveNudge.name = "proactiveNudge"
        proactiveNudge.attributeType = .booleanAttributeType
        proactiveNudge.isOptional = false
        proactiveNudge.defaultValue = true

        let lastInsightSummary = NSAttributeDescription()
        lastInsightSummary.name = "lastInsightSummary"
        lastInsightSummary.attributeType = .stringAttributeType
        lastInsightSummary.isOptional = true

        // MARK: 量化目标字段（三期 3a，全部可选/带默认值，轻量迁移安全）
        // 目标类型：process(过程型，默认) / cumulative(累积型) / target(达标型)
        let goalKind = NSAttributeDescription()
        goalKind.name = "goalKind"
        goalKind.attributeType = .stringAttributeType
        goalKind.isOptional = false
        goalKind.defaultValue = GoalKind.process.rawValue

        // 数值单位（km / kg / 元 / 本…）
        let metricUnit = NSAttributeDescription()
        metricUnit.name = "metricUnit"
        metricUnit.attributeType = .stringAttributeType
        metricUnit.isOptional = true

        // 目标数值（如 300km 的 300）
        let targetValue = NSAttributeDescription()
        targetValue.name = "targetValue"
        targetValue.attributeType = .doubleAttributeType
        targetValue.isOptional = true

        // 达标型：创建时的基线快照（如当时体重 75kg）
        let baselineValue = NSAttributeDescription()
        baselineValue.name = "baselineValue"
        baselineValue.attributeType = .doubleAttributeType
        baselineValue.isOptional = true

        // 累积型：累计起点（默认=目标创建时刻）；达标型也记录创建时刻供速率计算
        let baselineDate = NSAttributeDescription()
        baselineDate.name = "baselineDate"
        baselineDate.attributeType = .dateAttributeType
        baselineDate.isOptional = true

        // 数据来源：manual(手动记录) / habit(数值习惯) / ledger(账本)
        let metricSource = NSAttributeDescription()
        metricSource.name = "metricSource"
        metricSource.attributeType = .stringAttributeType
        metricSource.isOptional = true

        // habit 源指向的数值习惯
        let sourceHabitId = NSAttributeDescription()
        sourceHabitId.name = "sourceHabitId"
        sourceHabitId.attributeType = .UUIDAttributeType
        sourceHabitId.isOptional = true

        // 账本口径（v1 固定 "all" 全账本，预留单账户口径）
        let ledgerScope = NSAttributeDescription()
        ledgerScope.name = "ledgerScope"
        ledgerScope.attributeType = .stringAttributeType
        ledgerScope.isOptional = true

        goalEntity.properties = [
            id, title, summary, domain, iconEmoji, desiredOutcome, motivation, status,
            deadline, createdAt, updatedAt, completedAt, source, allowAIContext,
            proactiveNudge, lastInsightSummary,
            goalKind, metricUnit, targetValue, baselineValue, baselineDate,
            metricSource, sourceHabitId, ledgerScope
        ]
        return goalEntity
    }

    /// 量化目标手动记录实体（仅 manual 源使用；自动源不写任何中间记录）。
    /// 与 Goal 不建 Core Data 关系，用 goalId 外键关联——
    /// 记录数据独立于目标关系生命周期，进度每次展示时实时求和/取最新。
    nonisolated func createGoalMetricLogEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "GoalMetricLog"
        entity.managedObjectClassName = "GoalMetricLog"

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()

        // 关联的目标 ID（外键关联，不用 relationship）
        let goalId = NSAttributeDescription()
        goalId.name = "goalId"
        goalId.attributeType = .UUIDAttributeType
        goalId.isOptional = false
        goalId.defaultValue = UUID()

        // 记录归属日（补记历史时早于 createdAt）
        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.defaultValue = Date()

        // 记录数值（累积型=本次增量，达标型=当前水平）
        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .doubleAttributeType
        value.isOptional = false
        value.defaultValue = 0.0

        let note = NSAttributeDescription()
        note.name = "note"
        note.attributeType = .stringAttributeType
        note.isOptional = true

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()

        entity.properties = [id, goalId, date, value, note, createdAt]
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "goalId": goalId, "date": date])
        return entity
    }
}
