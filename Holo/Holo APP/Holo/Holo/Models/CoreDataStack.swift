//
//  CoreDataStack.swift
//  Holo
//
//  Core Data 数据栈管理器
//  负责管理 Core Data 的持久化容器、上下文和保存操作
//
//  ━━━━━━━━━━ iCloud 同步启用指南 ━━━━━━━━━━
//  当前使用 NSPersistentContainer，数据仅存储在本地。
//  要启用 iCloud 同步，请按以下步骤操作：
//
//  1. 在 Xcode 中启用 CloudKit 能力：
//     - 选择项目 Target → Signing & Capabilities
//     - 点击 "+ Capability" 添加 "iCloud"
//     - 勾选 "CloudKit" 并创建容器（如 iCloud.com.yourcompany.Holo）
//
//  2. 修改下方代码：
//     - 将 `NSPersistentContainer` 改为 `NSPersistentCloudKitContainer`
//     - 取消注释 CloudKit 相关配置
//
//  3. 首次启用后，在 CloudKit Dashboard 中验证 schema 自动创建
//
//  注意：CloudKit 同步需要真机测试，模拟器功能有限
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import CoreData

/// Core Data 数据栈单例
/// 提供统一的 Core Data 访问入口，确保数据一致性
/// 线程安全：支持后台线程预加载，主线程安全访问
class CoreDataStack {

    // MARK: - Singleton

    /// 共享实例
    nonisolated(unsafe) static let shared = CoreDataStack()

    // MARK: - Thread-Safe Properties

    /// 线程安全锁，保护 _persistentContainer 的读写
    nonisolated(unsafe) private let lock = NSLock()

    /// 持久化容器（线程安全存储）
    /// 通过 persistentContainer 计算属性访问
    nonisolated(unsafe) private var _persistentContainer: NSPersistentContainer?

    /// 持久化容器
    /// 线程安全：首次访问时自动初始化，后续访问直接返回缓存实例
    /// 可从任意线程安全访问（后台预加载或主线程 UI 操作）
    ///
    /// 【启用 iCloud 同步】将下方 NSPersistentContainer 改为 NSPersistentCloudKitContainer
    nonisolated var persistentContainer: NSPersistentContainer {
        lock.lock()
        defer { lock.unlock() }

        if let container = _persistentContainer {
            return container
        }

        let container = buildContainer()
        _persistentContainer = container
        return container
    }

    /// Core Data 是否已就绪（非阻塞检查）
    /// 用于在 async 上下文中判断是否需要等待后台初始化
    nonisolated var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _persistentContainer != nil
    }
    
    /// 构建并加载持久化容器
    /// 包含完整的 schema 创建、存储配置和加载逻辑
    nonisolated private func buildContainer() -> NSPersistentContainer {
        let model = createDataModel()

        // ━━━ 本地存储（当前使用）━━━
        let container = NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)

        // ━━━ iCloud 同步（取消注释以启用）━━━
        // let container = NSPersistentCloudKitContainer(name: "HoloDataModel", managedObjectModel: model)

        // 配置持久化存储
        if let description = container.persistentStoreDescriptions.first {
            // 使用 SQLite 存储
            description.url = URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")

            // 启用轻量级迁移（支持新增字段等 schema 变更）
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

            // 启用历史追踪（iCloud 同步必需）
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

            // 启用远程变更通知（iCloud 同步必需）
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // ━━━ iCloud 同步配置（取消注释以启用）━━━
            // description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            //     containerIdentifier: "iCloud.com.yourcompany.Holo"  // 替换为你的 CloudKit 容器 ID
            // )
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Core Data 存储加载失败：\(error.localizedDescription)")
            }
        }

        // 配置自动合并策略
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return container
    }

    /// 通过代码创建 Core Data 数据模型
    /// - Returns: NSManagedObjectModel
    nonisolated private func createDataModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        var entities: [NSEntityDescription] = []
        entities.append(contentsOf: createFinanceEntities())
        entities.append(contentsOf: createHabitEntities())
        entities.append(contentsOf: createTodoEntities())
        entities.append(contentsOf: createThoughtEntities())
        entities.append(contentsOf: createChatEntities())
        model.entities = entities
        return model
    }

    // MARK: - Finance Entities

    /// 创建财务相关实体（Transaction, Category, Account, HomeIconConfig, Budget）
    nonisolated private func createFinanceEntities() -> [NSEntityDescription] {
        // MARK: - Transaction Entity
        let transactionEntity = NSEntityDescription()
        transactionEntity.name = "Transaction"
        transactionEntity.managedObjectClassName = "Transaction"
        
        var attributes: [NSAttributeDescription] = []
        
        let transactionId = NSAttributeDescription()
        transactionId.name = "id"
        transactionId.attributeType = .UUIDAttributeType
        transactionId.isOptional = false
        transactionId.isIndexed = true
        attributes.append(transactionId)
        
        let amount = NSAttributeDescription()
        amount.name = "amount"
        amount.attributeType = .decimalAttributeType
        amount.isOptional = false
        attributes.append(amount)
        
        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false
        type.isIndexed = true
        attributes.append(type)
        
        // 不再使用 categoryId/accountId 属性，仅通过 relationship category/account 关联
        
        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.isIndexed = true
        attributes.append(date)
        
        let note = NSAttributeDescription()
        note.name = "note"
        note.attributeType = .stringAttributeType
        note.isOptional = true
        attributes.append(note)

        let remark = NSAttributeDescription()
        remark.name = "remark"
        remark.attributeType = .stringAttributeType
        remark.isOptional = true
        attributes.append(remark)

        let tags = NSAttributeDescription()
        tags.name = "tags"
        tags.attributeType = .transformableAttributeType
        tags.isOptional = true
        tags.attributeValueClassName = "NSArray"
        attributes.append(tags)
        
        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        attributes.append(createdAt)
        
        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        attributes.append(updatedAt)
        
        // Transaction 与 Category / Account 的关系（对应 Transaction.category / Transaction.account）
        let categoryRelation = NSRelationshipDescription()
        categoryRelation.name = "category"
        categoryRelation.destinationEntity = nil  // 稍后设置，避免循环引用
        categoryRelation.minCount = 1
        categoryRelation.maxCount = 1
        categoryRelation.isOptional = false
        
        let accountRelation = NSRelationshipDescription()
        accountRelation.name = "account"
        accountRelation.destinationEntity = nil
        accountRelation.minCount = 1
        accountRelation.maxCount = 1
        accountRelation.isOptional = false
        
        // 分期记账字段
        let installmentGroupId = NSAttributeDescription()
        installmentGroupId.name = "installmentGroupId"
        installmentGroupId.attributeType = .UUIDAttributeType
        installmentGroupId.isOptional = true
        installmentGroupId.isIndexed = true
        attributes.append(installmentGroupId)

        let installmentIndex = NSAttributeDescription()
        installmentIndex.name = "installmentIndex"
        installmentIndex.attributeType = .integer16AttributeType
        installmentIndex.isOptional = false
        installmentIndex.defaultValue = 0
        attributes.append(installmentIndex)

        let installmentTotal = NSAttributeDescription()
        installmentTotal.name = "installmentTotal"
        installmentTotal.attributeType = .integer16AttributeType
        installmentTotal.isOptional = false
        installmentTotal.defaultValue = 0
        attributes.append(installmentTotal)

        transactionEntity.properties = attributes + [categoryRelation, accountRelation]
        
        // MARK: - Category Entity
        let categoryEntity = NSEntityDescription()
        categoryEntity.name = "Category"
        categoryEntity.managedObjectClassName = "Category"
        
        var categoryAttributes: [NSAttributeDescription] = []
        
        let categoryIdAttr = NSAttributeDescription()
        categoryIdAttr.name = "id"
        categoryIdAttr.attributeType = .UUIDAttributeType
        categoryIdAttr.isOptional = false
        categoryIdAttr.isIndexed = true
        categoryAttributes.append(categoryIdAttr)
        
        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        categoryAttributes.append(name)
        
        let icon = NSAttributeDescription()
        icon.name = "icon"
        icon.attributeType = .stringAttributeType
        icon.isOptional = false
        categoryAttributes.append(icon)
        
        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = false
        categoryAttributes.append(color)
        
        let categoryType = NSAttributeDescription()
        categoryType.name = "type"
        categoryType.attributeType = .stringAttributeType
        categoryType.isOptional = false
        categoryType.isIndexed = true
        categoryAttributes.append(categoryType)
        
        let isDefault = NSAttributeDescription()
        isDefault.name = "isDefault"
        isDefault.attributeType = .booleanAttributeType
        isDefault.isOptional = false
        isDefault.isIndexed = true
        categoryAttributes.append(isDefault)
        
        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.isIndexed = true
        categoryAttributes.append(sortOrder)
        
        // 父分类 ID（用于二级分类层级关系）
        // 一级分类的 parentId 为 nil，二级分类通过此字段指向其一级分类
        let parentId = NSAttributeDescription()
        parentId.name = "parentId"
        parentId.attributeType = .UUIDAttributeType
        parentId.isOptional = true
        parentId.isIndexed = true
        categoryAttributes.append(parentId)

        // 是否为系统内置分类（不可删除/编辑，如"余额调整"）
        let isSystem = NSAttributeDescription()
        isSystem.name = "isSystem"
        isSystem.attributeType = .booleanAttributeType
        isSystem.isOptional = false
        isSystem.defaultValue = false
        categoryAttributes.append(isSystem)

        categoryEntity.properties = categoryAttributes
        
        // MARK: - Account Entity
        let accountEntity = NSEntityDescription()
        accountEntity.name = "Account"
        accountEntity.managedObjectClassName = "Account"
        
        var accountAttributes: [NSAttributeDescription] = []
        
        let accountIdAttr = NSAttributeDescription()
        accountIdAttr.name = "id"
        accountIdAttr.attributeType = .UUIDAttributeType
        accountIdAttr.isOptional = false
        accountIdAttr.isIndexed = true
        accountAttributes.append(accountIdAttr)
        
        let accountName = NSAttributeDescription()
        accountName.name = "name"
        accountName.attributeType = .stringAttributeType
        accountName.isOptional = false
        accountAttributes.append(accountName)
        
        let accountType = NSAttributeDescription()
        accountType.name = "type"
        accountType.attributeType = .stringAttributeType
        accountType.isOptional = false
        accountType.isIndexed = true
        accountAttributes.append(accountType)
        
        let accountIsDefault = NSAttributeDescription()
        accountIsDefault.name = "isDefault"
        accountIsDefault.attributeType = .booleanAttributeType
        accountIsDefault.isOptional = false
        accountIsDefault.isIndexed = true
        accountAttributes.append(accountIsDefault)

        // 开户余额（初始余额，用于实时计算当前余额）
        let accountInitialBalance = NSAttributeDescription()
        accountInitialBalance.name = "initialBalance"
        accountInitialBalance.attributeType = .decimalAttributeType
        accountInitialBalance.isOptional = false
        accountInitialBalance.defaultValue = NSDecimalNumber(value: 0)
        accountAttributes.append(accountInitialBalance)

        // 自定义 SF Symbol 图标（空则使用 AccountType 默认图标）
        let accountIcon = NSAttributeDescription()
        accountIcon.name = "customIcon"
        accountIcon.attributeType = .stringAttributeType
        accountIcon.isOptional = false
        accountIcon.defaultValue = ""
        accountAttributes.append(accountIcon)

        // 自定义颜色 hex
        let accountColor = NSAttributeDescription()
        accountColor.name = "color"
        accountColor.attributeType = .stringAttributeType
        accountColor.isOptional = false
        accountColor.defaultValue = "#64748B"
        accountAttributes.append(accountColor)

        // 排序权重
        let accountSortOrder = NSAttributeDescription()
        accountSortOrder.name = "sortOrder"
        accountSortOrder.attributeType = .integer16AttributeType
        accountSortOrder.isOptional = false
        accountSortOrder.defaultValue = 0
        accountSortOrder.isIndexed = true
        accountAttributes.append(accountSortOrder)

        // 是否归档
        let accountIsArchived = NSAttributeDescription()
        accountIsArchived.name = "isArchived"
        accountIsArchived.attributeType = .booleanAttributeType
        accountIsArchived.isOptional = false
        accountIsArchived.defaultValue = false
        accountAttributes.append(accountIsArchived)

        // 备注
        let accountNotes = NSAttributeDescription()
        accountNotes.name = "notes"
        accountNotes.attributeType = .stringAttributeType
        accountNotes.isOptional = true
        accountAttributes.append(accountNotes)

        // 创建时间
        let accountCreatedAt = NSAttributeDescription()
        accountCreatedAt.name = "createdAt"
        accountCreatedAt.attributeType = .dateAttributeType
        accountCreatedAt.isOptional = false
        accountCreatedAt.defaultValue = Date()
        accountAttributes.append(accountCreatedAt)

        // 更新时间
        let accountUpdatedAt = NSAttributeDescription()
        accountUpdatedAt.name = "updatedAt"
        accountUpdatedAt.attributeType = .dateAttributeType
        accountUpdatedAt.isOptional = false
        accountUpdatedAt.defaultValue = Date()
        accountAttributes.append(accountUpdatedAt)

        accountEntity.properties = accountAttributes
        
        // 绑定 Transaction 关系的目标实体（需在 Category/Account 创建后设置）
        categoryRelation.destinationEntity = categoryEntity
        accountRelation.destinationEntity = accountEntity
        
        // MARK: - HomeIconConfig Entity
        // 首页图标配置实体，支持排序、显示/隐藏、自定义名称等
        let homeIconConfigEntity = NSEntityDescription()
        homeIconConfigEntity.name = "HomeIconConfig"
        homeIconConfigEntity.managedObjectClassName = "HomeIconConfig"
        
        var homeIconAttributes: [NSAttributeDescription] = []
        
        // 图标唯一标识符（如 "task", "finance", "habit" 等）
        let iconId = NSAttributeDescription()
        iconId.name = "iconId"
        iconId.attributeType = .stringAttributeType
        iconId.isOptional = false
        iconId.isIndexed = true
        homeIconAttributes.append(iconId)
        
        // 排序顺序（0-based，数字越小越靠前）
        let iconSortOrder = NSAttributeDescription()
        iconSortOrder.name = "sortOrder"
        iconSortOrder.attributeType = .integer16AttributeType
        iconSortOrder.isOptional = false
        iconSortOrder.isIndexed = true
        homeIconAttributes.append(iconSortOrder)
        
        // 是否显示（支持用户隐藏某些图标）
        let iconIsVisible = NSAttributeDescription()
        iconIsVisible.name = "isVisible"
        iconIsVisible.attributeType = .booleanAttributeType
        iconIsVisible.isOptional = false
        iconIsVisible.defaultValue = true
        homeIconAttributes.append(iconIsVisible)
        
        // 自定义名称（可选，用户可修改显示名称）
        let iconCustomName = NSAttributeDescription()
        iconCustomName.name = "customName"
        iconCustomName.attributeType = .stringAttributeType
        iconCustomName.isOptional = true
        homeIconAttributes.append(iconCustomName)
        
        // 创建时间
        let iconCreatedAt = NSAttributeDescription()
        iconCreatedAt.name = "createdAt"
        iconCreatedAt.attributeType = .dateAttributeType
        iconCreatedAt.isOptional = false
        homeIconAttributes.append(iconCreatedAt)
        
        // 更新时间
        let iconUpdatedAt = NSAttributeDescription()
        iconUpdatedAt.name = "updatedAt"
        iconUpdatedAt.attributeType = .dateAttributeType
        iconUpdatedAt.isOptional = false
        homeIconAttributes.append(iconUpdatedAt)
        
        homeIconConfigEntity.properties = homeIconAttributes

        // MARK: - Budget Entity
        // 预算实体，支持账户级月度/周度/年度支出上限设置
        let budgetEntity = NSEntityDescription()
        budgetEntity.name = "Budget"
        budgetEntity.managedObjectClassName = "Budget"

        var budgetAttributes: [NSAttributeDescription] = []

        let budgetId = NSAttributeDescription()
        budgetId.name = "id"
        budgetId.attributeType = .UUIDAttributeType
        budgetId.isOptional = false
        budgetId.isIndexed = true
        budgetAttributes.append(budgetId)

        // 所属账户 ID（轻量 UUID 引用，非 Relationship）
        let budgetAccountId = NSAttributeDescription()
        budgetAccountId.name = "accountId"
        budgetAccountId.attributeType = .UUIDAttributeType
        budgetAccountId.isOptional = false
        budgetAccountId.isIndexed = true
        budgetAttributes.append(budgetAccountId)

        // 分类 ID（nil=总预算，非nil=分类预算 Phase 2）
        let budgetCategoryId = NSAttributeDescription()
        budgetCategoryId.name = "categoryId"
        budgetCategoryId.attributeType = .UUIDAttributeType
        budgetCategoryId.isOptional = true
        budgetCategoryId.isIndexed = true
        budgetAttributes.append(budgetCategoryId)

        // 预算金额
        let budgetAmount = NSAttributeDescription()
        budgetAmount.name = "amount"
        budgetAmount.attributeType = .decimalAttributeType
        budgetAmount.isOptional = false
        budgetAttributes.append(budgetAmount)

        // 预算周期（BudgetPeriod.rawValue: week/month/year）
        let budgetPeriod = NSAttributeDescription()
        budgetPeriod.name = "period"
        budgetPeriod.attributeType = .stringAttributeType
        budgetPeriod.isOptional = false
        budgetPeriod.isIndexed = true
        budgetAttributes.append(budgetPeriod)

        // 预算起始日期
        let budgetStartDate = NSAttributeDescription()
        budgetStartDate.name = "startDate"
        budgetStartDate.attributeType = .dateAttributeType
        budgetStartDate.isOptional = false
        budgetAttributes.append(budgetStartDate)

        let budgetCreatedAt = NSAttributeDescription()
        budgetCreatedAt.name = "createdAt"
        budgetCreatedAt.attributeType = .dateAttributeType
        budgetCreatedAt.isOptional = false
        budgetAttributes.append(budgetCreatedAt)

        let budgetUpdatedAt = NSAttributeDescription()
        budgetUpdatedAt.name = "updatedAt"
        budgetUpdatedAt.attributeType = .dateAttributeType
        budgetUpdatedAt.isOptional = false
        budgetAttributes.append(budgetUpdatedAt)

        budgetEntity.properties = budgetAttributes

        return [transactionEntity, categoryEntity, accountEntity, homeIconConfigEntity, budgetEntity]
    }

    // MARK: - Habit Entities

    /// 创建习惯相关实体（Habit, HabitRecord）
    nonisolated private func createHabitEntities() -> [NSEntityDescription] {
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
        habitId.isIndexed = true
        habitAttributes.append(habitId)
        
        // 习惯名称
        let habitName = NSAttributeDescription()
        habitName.name = "name"
        habitName.attributeType = .stringAttributeType
        habitName.isOptional = false
        habitAttributes.append(habitName)
        
        // SF Symbol 图标名称
        let habitIcon = NSAttributeDescription()
        habitIcon.name = "icon"
        habitIcon.attributeType = .stringAttributeType
        habitIcon.isOptional = false
        habitAttributes.append(habitIcon)
        
        // Hex 颜色值
        let habitColor = NSAttributeDescription()
        habitColor.name = "color"
        habitColor.attributeType = .stringAttributeType
        habitColor.isOptional = false
        habitAttributes.append(habitColor)
        
        // 习惯类型：0=打卡型, 1=数值型
        let habitType = NSAttributeDescription()
        habitType.name = "type"
        habitType.attributeType = .integer16AttributeType
        habitType.isOptional = false
        habitType.isIndexed = true
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
        habitIsArchived.isIndexed = true
        habitIsArchived.defaultValue = false
        habitAttributes.append(habitIsArchived)
        
        // 排序顺序
        let habitSortOrder = NSAttributeDescription()
        habitSortOrder.name = "sortOrder"
        habitSortOrder.attributeType = .integer16AttributeType
        habitSortOrder.isOptional = false
        habitSortOrder.isIndexed = true
        habitSortOrder.defaultValue = 0
        habitAttributes.append(habitSortOrder)
        
        // 创建时间
        let habitCreatedAt = NSAttributeDescription()
        habitCreatedAt.name = "createdAt"
        habitCreatedAt.attributeType = .dateAttributeType
        habitCreatedAt.isOptional = false
        habitAttributes.append(habitCreatedAt)
        
        // 更新时间
        let habitUpdatedAt = NSAttributeDescription()
        habitUpdatedAt.name = "updatedAt"
        habitUpdatedAt.attributeType = .dateAttributeType
        habitUpdatedAt.isOptional = false
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
        recordId.isIndexed = true
        habitRecordAttributes.append(recordId)
        
        // 关联的习惯 ID（用于查询，关系由 relationship 维护）
        let recordHabitId = NSAttributeDescription()
        recordHabitId.name = "habitId"
        recordHabitId.attributeType = .UUIDAttributeType
        recordHabitId.isOptional = false
        recordHabitId.isIndexed = true
        habitRecordAttributes.append(recordHabitId)
        
        // 记录时间（精确到秒，支持一天多次记录）
        let recordDate = NSAttributeDescription()
        recordDate.name = "date"
        recordDate.attributeType = .dateAttributeType
        recordDate.isOptional = false
        recordDate.isIndexed = true
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
        
        // 创建时间
        let recordCreatedAt = NSAttributeDescription()
        recordCreatedAt.name = "createdAt"
        recordCreatedAt.attributeType = .dateAttributeType
        recordCreatedAt.isOptional = false
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
        recordHabitRelation.minCount = 1
        recordHabitRelation.maxCount = 1
        recordHabitRelation.deleteRule = .nullifyDeleteRule
        recordHabitRelation.isOptional = false
        
        // 设置双向关系
        habitRecordsRelation.inverseRelationship = recordHabitRelation
        recordHabitRelation.inverseRelationship = habitRecordsRelation
        
        // 将关系添加到实体属性中
        habitEntity.properties = habitAttributes + [habitRecordsRelation]
        habitRecordEntity.properties = habitRecordAttributes + [recordHabitRelation]

        return [habitEntity, habitRecordEntity]
    }

    // MARK: - Todo Entities

    /// 创建待办相关实体（TodoFolder, TodoList, TodoTask, TodoTag, CheckItem, RepeatRule）
    nonisolated private func createTodoEntities() -> [NSEntityDescription] {
        // MARK: - TodoFolder Entity
        // 待办文件夹实体，顶层容器
        let todoFolderEntity = NSEntityDescription()
        todoFolderEntity.name = "TodoFolder"
        todoFolderEntity.managedObjectClassName = "TodoFolder"

        var todoFolderAttributes: [NSAttributeDescription] = []

        let folderId = NSAttributeDescription()
        folderId.name = "id"
        folderId.attributeType = .UUIDAttributeType
        folderId.isOptional = false
        folderId.isIndexed = true
        todoFolderAttributes.append(folderId)

        let folderName = NSAttributeDescription()
        folderName.name = "name"
        folderName.attributeType = .stringAttributeType
        folderName.isOptional = false
        todoFolderAttributes.append(folderName)

        let folderOrder = NSAttributeDescription()
        folderOrder.name = "sortOrder"
        folderOrder.attributeType = .integer16AttributeType
        folderOrder.isOptional = false
        folderOrder.defaultValue = 0
        todoFolderAttributes.append(folderOrder)

        let folderIsExpanded = NSAttributeDescription()
        folderIsExpanded.name = "isExpanded"
        folderIsExpanded.attributeType = .booleanAttributeType
        folderIsExpanded.isOptional = false
        folderIsExpanded.defaultValue = true
        todoFolderAttributes.append(folderIsExpanded)

        let folderCreatedAt = NSAttributeDescription()
        folderCreatedAt.name = "createdAt"
        folderCreatedAt.attributeType = .dateAttributeType
        folderCreatedAt.isOptional = false
        todoFolderAttributes.append(folderCreatedAt)

        let folderUpdatedAt = NSAttributeDescription()
        folderUpdatedAt.name = "updatedAt"
        folderUpdatedAt.attributeType = .dateAttributeType
        folderUpdatedAt.isOptional = false
        todoFolderAttributes.append(folderUpdatedAt)

        // MARK: - TodoList Entity
        // 待办清单实体，文件夹下的具体列表
        let todoListEntity = NSEntityDescription()
        todoListEntity.name = "TodoList"
        todoListEntity.managedObjectClassName = "TodoList"

        var todoListAttributes: [NSAttributeDescription] = []

        let listId = NSAttributeDescription()
        listId.name = "id"
        listId.attributeType = .UUIDAttributeType
        listId.isOptional = false
        listId.isIndexed = true
        todoListAttributes.append(listId)

        let listName = NSAttributeDescription()
        listName.name = "name"
        listName.attributeType = .stringAttributeType
        listName.isOptional = false
        todoListAttributes.append(listName)

        let listOrder = NSAttributeDescription()
        listOrder.name = "sortOrder"
        listOrder.attributeType = .integer16AttributeType
        listOrder.isOptional = false
        listOrder.defaultValue = 0
        todoListAttributes.append(listOrder)

        let listColor = NSAttributeDescription()
        listColor.name = "color"
        listColor.attributeType = .stringAttributeType
        listColor.isOptional = true
        todoListAttributes.append(listColor)

        let listIsArchived = NSAttributeDescription()
        listIsArchived.name = "archived"
        listIsArchived.attributeType = .booleanAttributeType
        listIsArchived.isOptional = false
        listIsArchived.defaultValue = false
        todoListAttributes.append(listIsArchived)

        let listCreatedAt = NSAttributeDescription()
        listCreatedAt.name = "createdAt"
        listCreatedAt.attributeType = .dateAttributeType
        listCreatedAt.isOptional = false
        todoListAttributes.append(listCreatedAt)

        let listUpdatedAt = NSAttributeDescription()
        listUpdatedAt.name = "updatedAt"
        listUpdatedAt.attributeType = .dateAttributeType
        listUpdatedAt.isOptional = false
        todoListAttributes.append(listUpdatedAt)

        // MARK: - TodoTask Entity
        // 待办任务实体
        let todoTaskEntity = NSEntityDescription()
        todoTaskEntity.name = "TodoTask"
        todoTaskEntity.managedObjectClassName = "TodoTask"

        var todoTaskAttributes: [NSAttributeDescription] = []

        let taskId = NSAttributeDescription()
        taskId.name = "id"
        taskId.attributeType = .UUIDAttributeType
        taskId.isOptional = false
        taskId.isIndexed = true
        todoTaskAttributes.append(taskId)

        let taskTitle = NSAttributeDescription()
        taskTitle.name = "title"
        taskTitle.attributeType = .stringAttributeType
        taskTitle.isOptional = false
        todoTaskAttributes.append(taskTitle)

        let taskDescription = NSAttributeDescription()
        taskDescription.name = "desc"
        taskDescription.attributeType = .stringAttributeType
        taskDescription.isOptional = true
        todoTaskAttributes.append(taskDescription)

        let taskStatus = NSAttributeDescription()
        taskStatus.name = "status"
        taskStatus.attributeType = .stringAttributeType
        taskStatus.isOptional = false
        taskStatus.defaultValue = "todo"
        taskStatus.isIndexed = true
        todoTaskAttributes.append(taskStatus)

        let taskPriority = NSAttributeDescription()
        taskPriority.name = "priority"
        taskPriority.attributeType = .integer16AttributeType
        taskPriority.isOptional = false
        taskPriority.defaultValue = 1
        taskPriority.isIndexed = true
        todoTaskAttributes.append(taskPriority)

        let taskDueDate = NSAttributeDescription()
        taskDueDate.name = "dueDate"
        taskDueDate.attributeType = .dateAttributeType
        taskDueDate.isOptional = true
        taskDueDate.isIndexed = true
        todoTaskAttributes.append(taskDueDate)

        let taskIsAllDay = NSAttributeDescription()
        taskIsAllDay.name = "isAllDay"
        taskIsAllDay.attributeType = .booleanAttributeType
        taskIsAllDay.isOptional = false
        taskIsAllDay.defaultValue = false
        todoTaskAttributes.append(taskIsAllDay)

        let taskIsCompleted = NSAttributeDescription()
        taskIsCompleted.name = "completed"
        taskIsCompleted.attributeType = .booleanAttributeType
        taskIsCompleted.isOptional = false
        taskIsCompleted.defaultValue = false
        taskIsCompleted.isIndexed = true
        todoTaskAttributes.append(taskIsCompleted)

        let taskCompletedAt = NSAttributeDescription()
        taskCompletedAt.name = "completedAt"
        taskCompletedAt.attributeType = .dateAttributeType
        taskCompletedAt.isOptional = true
        todoTaskAttributes.append(taskCompletedAt)

        let taskIsArchived = NSAttributeDescription()
        taskIsArchived.name = "archived"
        taskIsArchived.attributeType = .booleanAttributeType
        taskIsArchived.isOptional = false
        taskIsArchived.defaultValue = false
        taskIsArchived.isIndexed = true
        todoTaskAttributes.append(taskIsArchived)

        let taskDeletedFlag = NSAttributeDescription()
        taskDeletedFlag.name = "deletedFlag"
        taskDeletedFlag.attributeType = .booleanAttributeType
        taskDeletedFlag.isOptional = false
        taskDeletedFlag.defaultValue = false
        taskDeletedFlag.isIndexed = true
        todoTaskAttributes.append(taskDeletedFlag)

        let taskDeletedAt = NSAttributeDescription()
        taskDeletedAt.name = "deletedAt"
        taskDeletedAt.attributeType = .dateAttributeType
        taskDeletedAt.isOptional = true
        todoTaskAttributes.append(taskDeletedAt)

        let taskCreatedAt = NSAttributeDescription()
        taskCreatedAt.name = "createdAt"
        taskCreatedAt.attributeType = .dateAttributeType
        taskCreatedAt.isOptional = false
        todoTaskAttributes.append(taskCreatedAt)

        let taskUpdatedAt = NSAttributeDescription()
        taskUpdatedAt.name = "updatedAt"
        taskUpdatedAt.attributeType = .dateAttributeType
        taskUpdatedAt.isOptional = false
        todoTaskAttributes.append(taskUpdatedAt)

        // 提醒相关属性
        let taskReminders = NSAttributeDescription()
        taskReminders.name = "reminders"
        taskReminders.attributeType = .transformableAttributeType
        taskReminders.isOptional = true
        taskReminders.valueTransformerName = "NSSecureUnarchiveFromData"
        todoTaskAttributes.append(taskReminders)

        let taskHasDailyReminder = NSAttributeDescription()
        taskHasDailyReminder.name = "hasDailyReminder"
        taskHasDailyReminder.attributeType = .booleanAttributeType
        taskHasDailyReminder.isOptional = false
        taskHasDailyReminder.defaultValue = false
        todoTaskAttributes.append(taskHasDailyReminder)

        let taskSmartReminderEnabled = NSAttributeDescription()
        taskSmartReminderEnabled.name = "smartReminderEnabled"
        taskSmartReminderEnabled.attributeType = .booleanAttributeType
        taskSmartReminderEnabled.isOptional = false
        taskSmartReminderEnabled.defaultValue = false
        todoTaskAttributes.append(taskSmartReminderEnabled)

        let taskSmartReminderSchedule = NSAttributeDescription()
        taskSmartReminderSchedule.name = "smartReminderSchedule"
        taskSmartReminderSchedule.attributeType = .transformableAttributeType
        taskSmartReminderSchedule.isOptional = true
        taskSmartReminderSchedule.valueTransformerName = "NSSecureUnarchiveFromData"
        todoTaskAttributes.append(taskSmartReminderSchedule)

        // MARK: - TodoTag Entity
        // 待办标签实体
        let todoTagEntity = NSEntityDescription()
        todoTagEntity.name = "TodoTag"
        todoTagEntity.managedObjectClassName = "TodoTag"

        var todoTagAttributes: [NSAttributeDescription] = []

        let tagId = NSAttributeDescription()
        tagId.name = "id"
        tagId.attributeType = .UUIDAttributeType
        tagId.isOptional = false
        tagId.isIndexed = true
        todoTagAttributes.append(tagId)

        let tagName = NSAttributeDescription()
        tagName.name = "name"
        tagName.attributeType = .stringAttributeType
        tagName.isOptional = false
        todoTagAttributes.append(tagName)

        let tagColor = NSAttributeDescription()
        tagColor.name = "color"
        tagColor.attributeType = .stringAttributeType
        tagColor.isOptional = false
        todoTagAttributes.append(tagColor)

        let tagDeletedFlag = NSAttributeDescription()
        tagDeletedFlag.name = "deletedFlag"
        tagDeletedFlag.attributeType = .booleanAttributeType
        tagDeletedFlag.isOptional = false
        tagDeletedFlag.defaultValue = false
        todoTagAttributes.append(tagDeletedFlag)

        let tagCreatedAt = NSAttributeDescription()
        tagCreatedAt.name = "createdAt"
        tagCreatedAt.attributeType = .dateAttributeType
        tagCreatedAt.isOptional = false
        todoTagAttributes.append(tagCreatedAt)

        // MARK: - CheckItem Entity
        // 检查项实体（任务子步骤）
        let checkItemEntity = NSEntityDescription()
        checkItemEntity.name = "CheckItem"
        checkItemEntity.managedObjectClassName = "CheckItem"

        var checkItemAttributes: [NSAttributeDescription] = []

        let checkItemId = NSAttributeDescription()
        checkItemId.name = "id"
        checkItemId.attributeType = .UUIDAttributeType
        checkItemId.isOptional = false
        checkItemId.isIndexed = true
        checkItemAttributes.append(checkItemId)

        let checkItemTitle = NSAttributeDescription()
        checkItemTitle.name = "title"
        checkItemTitle.attributeType = .stringAttributeType
        checkItemTitle.isOptional = false
        checkItemAttributes.append(checkItemTitle)

        let checkItemIsChecked = NSAttributeDescription()
        checkItemIsChecked.name = "isChecked"
        checkItemIsChecked.attributeType = .booleanAttributeType
        checkItemIsChecked.isOptional = false
        checkItemIsChecked.defaultValue = false
        checkItemAttributes.append(checkItemIsChecked)

        let checkItemOrder = NSAttributeDescription()
        checkItemOrder.name = "order"
        checkItemOrder.attributeType = .integer16AttributeType
        checkItemOrder.isOptional = false
        checkItemOrder.defaultValue = 0
        checkItemAttributes.append(checkItemOrder)

        let checkItemCreatedAt = NSAttributeDescription()
        checkItemCreatedAt.name = "createdAt"
        checkItemCreatedAt.attributeType = .dateAttributeType
        checkItemCreatedAt.isOptional = false
        checkItemAttributes.append(checkItemCreatedAt)

        // MARK: - RepeatRule Entity
        // 重复规则实体
        let repeatRuleEntity = NSEntityDescription()
        repeatRuleEntity.name = "RepeatRule"
        repeatRuleEntity.managedObjectClassName = "RepeatRule"

        var repeatRuleAttributes: [NSAttributeDescription] = []

        let ruleId = NSAttributeDescription()
        ruleId.name = "id"
        ruleId.attributeType = .UUIDAttributeType
        ruleId.isOptional = false
        ruleId.isIndexed = true
        repeatRuleAttributes.append(ruleId)

        let ruleType = NSAttributeDescription()
        ruleType.name = "type"
        ruleType.attributeType = .stringAttributeType
        ruleType.isOptional = false
        repeatRuleAttributes.append(ruleType)

        let ruleWeekdays = NSAttributeDescription()
        ruleWeekdays.name = "weekdays"
        ruleWeekdays.attributeType = .stringAttributeType
        ruleWeekdays.isOptional = true
        repeatRuleAttributes.append(ruleWeekdays)

        let ruleMonthDay = NSAttributeDescription()
        ruleMonthDay.name = "monthDay"
        ruleMonthDay.attributeType = .integer16AttributeType
        ruleMonthDay.isOptional = true
        repeatRuleAttributes.append(ruleMonthDay)

        let ruleMonthWeekOrdinal = NSAttributeDescription()
        ruleMonthWeekOrdinal.name = "monthWeekOrdinal"
        ruleMonthWeekOrdinal.attributeType = .integer16AttributeType
        ruleMonthWeekOrdinal.isOptional = true
        repeatRuleAttributes.append(ruleMonthWeekOrdinal)

        let ruleMonthWeekday = NSAttributeDescription()
        ruleMonthWeekday.name = "monthWeekday"
        ruleMonthWeekday.attributeType = .stringAttributeType
        ruleMonthWeekday.isOptional = true
        repeatRuleAttributes.append(ruleMonthWeekday)

        let ruleUntilCount = NSAttributeDescription()
        ruleUntilCount.name = "untilCount"
        ruleUntilCount.attributeType = .integer16AttributeType
        ruleUntilCount.isOptional = true
        repeatRuleAttributes.append(ruleUntilCount)

        let ruleUntilDate = NSAttributeDescription()
        ruleUntilDate.name = "untilDate"
        ruleUntilDate.attributeType = .dateAttributeType
        ruleUntilDate.isOptional = true
        repeatRuleAttributes.append(ruleUntilDate)

        let ruleSkipHolidays = NSAttributeDescription()
        ruleSkipHolidays.name = "skipHolidays"
        ruleSkipHolidays.attributeType = .booleanAttributeType
        ruleSkipHolidays.isOptional = false
        ruleSkipHolidays.defaultValue = false
        repeatRuleAttributes.append(ruleSkipHolidays)

        let ruleSkipWeekends = NSAttributeDescription()
        ruleSkipWeekends.name = "skipWeekends"
        ruleSkipWeekends.attributeType = .booleanAttributeType
        ruleSkipWeekends.isOptional = false
        ruleSkipWeekends.defaultValue = false
        repeatRuleAttributes.append(ruleSkipWeekends)

        let ruleCreatedAt = NSAttributeDescription()
        ruleCreatedAt.name = "createdAt"
        ruleCreatedAt.attributeType = .dateAttributeType
        ruleCreatedAt.isOptional = false
        repeatRuleAttributes.append(ruleCreatedAt)

        // MARK: - Todo Entity Relationships

        // TodoFolder ↔ TodoList 关系
        let folderListsRelation = NSRelationshipDescription()
        folderListsRelation.name = "lists"
        folderListsRelation.destinationEntity = todoListEntity
        folderListsRelation.minCount = 0
        folderListsRelation.maxCount = 0
        folderListsRelation.deleteRule = .cascadeDeleteRule
        folderListsRelation.isOptional = true

        let listFolderRelation = NSRelationshipDescription()
        listFolderRelation.name = "folder"
        listFolderRelation.destinationEntity = todoFolderEntity
        listFolderRelation.minCount = 0
        listFolderRelation.maxCount = 1
        listFolderRelation.deleteRule = .nullifyDeleteRule
        listFolderRelation.isOptional = true

        folderListsRelation.inverseRelationship = listFolderRelation
        listFolderRelation.inverseRelationship = folderListsRelation

        // TodoList ↔ TodoTask 关系
        let listTasksRelation = NSRelationshipDescription()
        listTasksRelation.name = "tasks"
        listTasksRelation.destinationEntity = todoTaskEntity
        listTasksRelation.minCount = 0
        listTasksRelation.maxCount = 0
        listTasksRelation.deleteRule = .cascadeDeleteRule
        listTasksRelation.isOptional = true

        let taskListRelation = NSRelationshipDescription()
        taskListRelation.name = "list"
        taskListRelation.destinationEntity = todoListEntity
        taskListRelation.minCount = 0
        taskListRelation.maxCount = 1
        taskListRelation.deleteRule = .nullifyDeleteRule
        taskListRelation.isOptional = true

        listTasksRelation.inverseRelationship = taskListRelation
        taskListRelation.inverseRelationship = listTasksRelation

        // TodoTask ↔ TodoTag 关系（多对多）
        let taskTagsRelation = NSRelationshipDescription()
        taskTagsRelation.name = "tags"
        taskTagsRelation.destinationEntity = todoTagEntity
        taskTagsRelation.minCount = 0
        taskTagsRelation.maxCount = 0
        taskTagsRelation.deleteRule = .nullifyDeleteRule
        taskTagsRelation.isOptional = true

        let tagTasksRelation = NSRelationshipDescription()
        tagTasksRelation.name = "tasks"
        tagTasksRelation.destinationEntity = todoTaskEntity
        tagTasksRelation.minCount = 0
        tagTasksRelation.maxCount = 0
        tagTasksRelation.deleteRule = .nullifyDeleteRule
        tagTasksRelation.isOptional = true

        taskTagsRelation.inverseRelationship = tagTasksRelation
        tagTasksRelation.inverseRelationship = taskTagsRelation

        // TodoTask ↔ CheckItem 关系（一对多）
        let taskCheckItemsRelation = NSRelationshipDescription()
        taskCheckItemsRelation.name = "checkItems"
        taskCheckItemsRelation.destinationEntity = checkItemEntity
        taskCheckItemsRelation.minCount = 0
        taskCheckItemsRelation.maxCount = 0
        taskCheckItemsRelation.deleteRule = .cascadeDeleteRule
        taskCheckItemsRelation.isOptional = true

        let checkItemTaskRelation = NSRelationshipDescription()
        checkItemTaskRelation.name = "task"
        checkItemTaskRelation.destinationEntity = todoTaskEntity
        checkItemTaskRelation.minCount = 1
        checkItemTaskRelation.maxCount = 1
        checkItemTaskRelation.deleteRule = .cascadeDeleteRule
        checkItemTaskRelation.isOptional = false

        taskCheckItemsRelation.inverseRelationship = checkItemTaskRelation
        checkItemTaskRelation.inverseRelationship = taskCheckItemsRelation

        // TodoTask ↔ RepeatRule 关系（一对一）
        let taskRepeatRuleRelation = NSRelationshipDescription()
        taskRepeatRuleRelation.name = "repeatRule"
        taskRepeatRuleRelation.destinationEntity = repeatRuleEntity
        taskRepeatRuleRelation.minCount = 0
        taskRepeatRuleRelation.maxCount = 1
        taskRepeatRuleRelation.deleteRule = .cascadeDeleteRule
        taskRepeatRuleRelation.isOptional = true

        let ruleTaskRelation = NSRelationshipDescription()
        ruleTaskRelation.name = "task"
        ruleTaskRelation.destinationEntity = todoTaskEntity
        ruleTaskRelation.minCount = 0
        ruleTaskRelation.maxCount = 1
        ruleTaskRelation.deleteRule = .nullifyDeleteRule
        ruleTaskRelation.isOptional = true

        taskRepeatRuleRelation.inverseRelationship = ruleTaskRelation
        ruleTaskRelation.inverseRelationship = taskRepeatRuleRelation

        // 将关系添加到实体
        todoFolderEntity.properties = todoFolderAttributes + [folderListsRelation]
        todoListEntity.properties = todoListAttributes + [listFolderRelation, listTasksRelation]
        todoTaskEntity.properties = todoTaskAttributes + [taskListRelation, taskTagsRelation, taskCheckItemsRelation, taskRepeatRuleRelation]
        todoTagEntity.properties = todoTagAttributes + [tagTasksRelation]
        checkItemEntity.properties = checkItemAttributes + [checkItemTaskRelation]
        repeatRuleEntity.properties = repeatRuleAttributes + [ruleTaskRelation]

        return [todoFolderEntity, todoListEntity, todoTaskEntity, todoTagEntity, checkItemEntity, repeatRuleEntity]
    }

    // MARK: - Thought Entities

    /// 创建观点相关实体（Thought, ThoughtTag, ThoughtReference）
    nonisolated private func createThoughtEntities() -> [NSEntityDescription] {
        // MARK: - Thought Entity
        // 观点模块 - 想法实体
        let thoughtEntity = NSEntityDescription()
        thoughtEntity.name = "Thought"
        thoughtEntity.managedObjectClassName = "Thought"

        var thoughtAttributes: [NSAttributeDescription] = []

        let thoughtId = NSAttributeDescription()
        thoughtId.name = "id"
        thoughtId.attributeType = .UUIDAttributeType
        thoughtId.isOptional = false
        thoughtId.isIndexed = true
        thoughtAttributes.append(thoughtId)

        let thoughtContent = NSAttributeDescription()
        thoughtContent.name = "content"
        thoughtContent.attributeType = .stringAttributeType
        thoughtContent.isOptional = false
        thoughtAttributes.append(thoughtContent)

        let thoughtCreatedAt = NSAttributeDescription()
        thoughtCreatedAt.name = "createdAt"
        thoughtCreatedAt.attributeType = .dateAttributeType
        thoughtCreatedAt.isOptional = false
        thoughtAttributes.append(thoughtCreatedAt)

        let thoughtUpdatedAt = NSAttributeDescription()
        thoughtUpdatedAt.name = "updatedAt"
        thoughtUpdatedAt.attributeType = .dateAttributeType
        thoughtUpdatedAt.isOptional = false
        thoughtAttributes.append(thoughtUpdatedAt)

        let thoughtMood = NSAttributeDescription()
        thoughtMood.name = "mood"
        thoughtMood.attributeType = .stringAttributeType
        thoughtMood.isOptional = true
        thoughtAttributes.append(thoughtMood)

        let thoughtOrderIndex = NSAttributeDescription()
        thoughtOrderIndex.name = "orderIndex"
        thoughtOrderIndex.attributeType = .integer16AttributeType
        thoughtOrderIndex.isOptional = false
        thoughtOrderIndex.defaultValue = 0
        thoughtAttributes.append(thoughtOrderIndex)

        let thoughtImageData = NSAttributeDescription()
        thoughtImageData.name = "imageData"
        thoughtImageData.attributeType = .binaryDataAttributeType
        thoughtImageData.isOptional = true
        thoughtAttributes.append(thoughtImageData)

        let thoughtIsSoftDeleted = NSAttributeDescription()
        thoughtIsSoftDeleted.name = "isSoftDeleted"
        thoughtIsSoftDeleted.attributeType = .booleanAttributeType
        thoughtIsSoftDeleted.isOptional = false
        thoughtIsSoftDeleted.defaultValue = false
        thoughtAttributes.append(thoughtIsSoftDeleted)

        let thoughtIsArchived = NSAttributeDescription()
        thoughtIsArchived.name = "isArchived"
        thoughtIsArchived.attributeType = .booleanAttributeType
        thoughtIsArchived.isOptional = false
        thoughtIsArchived.defaultValue = false
        thoughtAttributes.append(thoughtIsArchived)

        // MARK: - ThoughtTag Entity
        // 观点模块 - 标签实体
        let thoughtTagEntity = NSEntityDescription()
        thoughtTagEntity.name = "ThoughtTag"
        thoughtTagEntity.managedObjectClassName = "ThoughtTag"

        var thoughtTagAttributes: [NSAttributeDescription] = []

        let thoughtTagId = NSAttributeDescription()
        thoughtTagId.name = "id"
        thoughtTagId.attributeType = .UUIDAttributeType
        thoughtTagId.isOptional = false
        thoughtTagId.isIndexed = true
        thoughtTagAttributes.append(thoughtTagId)

        let thoughtTagName = NSAttributeDescription()
        thoughtTagName.name = "name"
        thoughtTagName.attributeType = .stringAttributeType
        thoughtTagName.isOptional = false
        thoughtTagAttributes.append(thoughtTagName)

        let thoughtTagColor = NSAttributeDescription()
        thoughtTagColor.name = "color"
        thoughtTagColor.attributeType = .stringAttributeType
        thoughtTagColor.isOptional = true
        thoughtTagAttributes.append(thoughtTagColor)

        let thoughtTagUsageCount = NSAttributeDescription()
        thoughtTagUsageCount.name = "usageCount"
        thoughtTagUsageCount.attributeType = .integer16AttributeType
        thoughtTagUsageCount.isOptional = false
        thoughtTagUsageCount.defaultValue = 0
        thoughtTagAttributes.append(thoughtTagUsageCount)

        // MARK: - ThoughtReference Entity
        // 观点模块 - 引用关系实体
        let thoughtReferenceEntity = NSEntityDescription()
        thoughtReferenceEntity.name = "ThoughtReference"
        thoughtReferenceEntity.managedObjectClassName = "ThoughtReference"

        var thoughtReferenceAttributes: [NSAttributeDescription] = []

        let thoughtReferenceId = NSAttributeDescription()
        thoughtReferenceId.name = "id"
        thoughtReferenceId.attributeType = .UUIDAttributeType
        thoughtReferenceId.isOptional = false
        thoughtReferenceId.isIndexed = true
        thoughtReferenceAttributes.append(thoughtReferenceId)

        let thoughtReferenceCreatedAt = NSAttributeDescription()
        thoughtReferenceCreatedAt.name = "createdAt"
        thoughtReferenceCreatedAt.attributeType = .dateAttributeType
        thoughtReferenceCreatedAt.isOptional = false
        thoughtReferenceAttributes.append(thoughtReferenceCreatedAt)

        // MARK: - Thought Relationships

        // Thought ↔ ThoughtTag（多对多）
        let thoughtTagsRelation = NSRelationshipDescription()
        thoughtTagsRelation.name = "tags"
        thoughtTagsRelation.destinationEntity = thoughtTagEntity
        thoughtTagsRelation.minCount = 0
        thoughtTagsRelation.maxCount = 0
        thoughtTagsRelation.deleteRule = .nullifyDeleteRule
        thoughtTagsRelation.isOptional = true

        let tagThoughtsRelation = NSRelationshipDescription()
        tagThoughtsRelation.name = "thoughts"
        tagThoughtsRelation.destinationEntity = thoughtEntity
        tagThoughtsRelation.minCount = 0
        tagThoughtsRelation.maxCount = 0
        tagThoughtsRelation.deleteRule = .nullifyDeleteRule
        tagThoughtsRelation.isOptional = true

        thoughtTagsRelation.inverseRelationship = tagThoughtsRelation
        tagThoughtsRelation.inverseRelationship = thoughtTagsRelation

        // Thought → ThoughtReference（正向引用：该想法引用了哪些其他想法）
        let thoughtReferencesRelation = NSRelationshipDescription()
        thoughtReferencesRelation.name = "references"
        thoughtReferencesRelation.destinationEntity = thoughtReferenceEntity
        thoughtReferencesRelation.minCount = 0
        thoughtReferencesRelation.maxCount = 0
        thoughtReferencesRelation.deleteRule = .cascadeDeleteRule
        thoughtReferencesRelation.isOptional = true

        // Thought → ThoughtReference（反向引用：该想法被哪些其他想法引用）
        let thoughtReferencedByRelation = NSRelationshipDescription()
        thoughtReferencedByRelation.name = "referencedBy"
        thoughtReferencedByRelation.destinationEntity = thoughtReferenceEntity
        thoughtReferencedByRelation.minCount = 0
        thoughtReferencedByRelation.maxCount = 0
        thoughtReferencedByRelation.deleteRule = .cascadeDeleteRule
        thoughtReferencedByRelation.isOptional = true

        // ThoughtReference → Thought（引用发起方）
        let referenceSourceRelation = NSRelationshipDescription()
        referenceSourceRelation.name = "sourceThought"
        referenceSourceRelation.destinationEntity = thoughtEntity
        referenceSourceRelation.minCount = 1
        referenceSourceRelation.maxCount = 1
        referenceSourceRelation.deleteRule = .nullifyDeleteRule
        referenceSourceRelation.isOptional = false

        // ThoughtReference → Thought（被引用方）
        let referenceTargetRelation = NSRelationshipDescription()
        referenceTargetRelation.name = "targetThought"
        referenceTargetRelation.destinationEntity = thoughtEntity
        referenceTargetRelation.minCount = 1
        referenceTargetRelation.maxCount = 1
        referenceTargetRelation.deleteRule = .nullifyDeleteRule
        referenceTargetRelation.isOptional = false

        // 设置双向关系
        thoughtReferencesRelation.inverseRelationship = referenceSourceRelation
        referenceSourceRelation.inverseRelationship = thoughtReferencesRelation

        thoughtReferencedByRelation.inverseRelationship = referenceTargetRelation
        referenceTargetRelation.inverseRelationship = thoughtReferencedByRelation

        // 将属性和关系添加到实体
        thoughtEntity.properties = thoughtAttributes + [thoughtTagsRelation, thoughtReferencesRelation, thoughtReferencedByRelation]
        thoughtTagEntity.properties = thoughtTagAttributes + [tagThoughtsRelation]
        thoughtReferenceEntity.properties = thoughtReferenceAttributes + [referenceSourceRelation, referenceTargetRelation]

        return [thoughtEntity, thoughtTagEntity, thoughtReferenceEntity]
    }

    // MARK: - Chat Entities

    /// 创建 AI 对话相关实体（ChatMessage）
    nonisolated private func createChatEntities() -> [NSEntityDescription] {
        let chatMessageEntity = NSEntityDescription()
        chatMessageEntity.name = "ChatMessage"
        chatMessageEntity.managedObjectClassName = "ChatMessage"

        var chatAttributes: [NSAttributeDescription] = []

        let chatId = NSAttributeDescription()
        chatId.name = "id"
        chatId.attributeType = .UUIDAttributeType
        chatId.isOptional = false
        chatId.isIndexed = true
        chatAttributes.append(chatId)

        let chatRole = NSAttributeDescription()
        chatRole.name = "role"
        chatRole.attributeType = .stringAttributeType
        chatRole.isOptional = false
        chatAttributes.append(chatRole)

        let chatContent = NSAttributeDescription()
        chatContent.name = "content"
        chatContent.attributeType = .stringAttributeType
        chatContent.isOptional = false
        chatAttributes.append(chatContent)

        let chatTimestamp = NSAttributeDescription()
        chatTimestamp.name = "timestamp"
        chatTimestamp.attributeType = .dateAttributeType
        chatTimestamp.isOptional = false
        chatTimestamp.isIndexed = true
        chatAttributes.append(chatTimestamp)

        let chatIntent = NSAttributeDescription()
        chatIntent.name = "intent"
        chatIntent.attributeType = .stringAttributeType
        chatIntent.isOptional = true
        chatAttributes.append(chatIntent)

        let chatExtractedData = NSAttributeDescription()
        chatExtractedData.name = "extractedDataJSON"
        chatExtractedData.attributeType = .stringAttributeType
        chatExtractedData.isOptional = true
        chatAttributes.append(chatExtractedData)

        let chatIsStreaming = NSAttributeDescription()
        chatIsStreaming.name = "isStreaming"
        chatIsStreaming.attributeType = .booleanAttributeType
        chatIsStreaming.isOptional = false
        chatIsStreaming.defaultValue = false
        chatAttributes.append(chatIsStreaming)

        let chatParentMessageId = NSAttributeDescription()
        chatParentMessageId.name = "parentMessageId"
        chatParentMessageId.attributeType = .UUIDAttributeType
        chatParentMessageId.isOptional = true
        chatAttributes.append(chatParentMessageId)

        let chatParsedBatch = NSAttributeDescription()
        chatParsedBatch.name = "parsedBatchJSON"
        chatParsedBatch.attributeType = .stringAttributeType
        chatParsedBatch.isOptional = true
        chatAttributes.append(chatParsedBatch)

        let chatExecutionBatch = NSAttributeDescription()
        chatExecutionBatch.name = "executionBatchJSON"
        chatExecutionBatch.attributeType = .stringAttributeType
        chatExecutionBatch.isOptional = true
        chatAttributes.append(chatExecutionBatch)

        chatMessageEntity.properties = chatAttributes

        return [chatMessageEntity]
    }

    /// 主上下文（用于 UI 操作）
    nonisolated var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    // MARK: - Initialization
    
    /// 私有初始化方法（单例模式）
    nonisolated private init() {}
    
    // MARK: - Context Management
    
    /// 创建新的后台上下文
    /// 用于执行耗时的数据操作，避免阻塞主线程
    nonisolated func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    /// 执行后台任务
    /// 在后台上下文中执行闭包，完成后自动保存
    nonisolated func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                do {
                    let result = try block(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Save Operations
    
    /// 保存主上下文
    /// 将更改写入持久化存储
    func save() throws {
        let context = viewContext
        if context.hasChanges {
            try context.save()
        }
    }
    
    /// 保存指定上下文
    func save(_ context: NSManagedObjectContext) throws {
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Reset
    
    /// 重置数据栈（用于开发调试）
    /// 警告：这将删除所有数据
    func reset() throws {
        let coordinator = persistentContainer.persistentStoreCoordinator
        
        // 删除所有存储
        for store in coordinator.persistentStores {
            try coordinator.destroyPersistentStore(
                at: store.url ?? URL(fileURLWithPath: "/dev/null"),
                type: NSPersistentStore.StoreType(rawValue: store.type),
                options: nil
            )
        }
        
        // 重新加载存储
        persistentContainer.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data 重置失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Helper Extensions

extension NSManagedObjectContext {
    /// 批量插入对象
    /// 提高大量数据插入时的性能
    func batchInsert<T: NSManagedObject>(
        entities: [T],
        batchSize: Int = 100
    ) throws {
        for (index, entity) in entities.enumerated() {
            insert(entity)
            
            // 每 batchSize 条保存一次，避免内存占用过高
            if (index + 1) % batchSize == 0 {
                try save()
                refreshAllObjects()
            }
        }
        
        // 保存剩余数据
        if !hasChanges {
            try save()
        }
    }
}
