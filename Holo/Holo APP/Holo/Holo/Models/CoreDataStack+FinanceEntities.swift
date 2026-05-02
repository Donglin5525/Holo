//
//  CoreDataStack+FinanceEntities.swift
//  Holo
//
//  财务相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Finance Entities

    /// 创建财务相关实体（Transaction, Category, Account, HomeIconConfig, Budget）
    nonisolated func createFinanceEntities() -> [NSEntityDescription] {
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

}
