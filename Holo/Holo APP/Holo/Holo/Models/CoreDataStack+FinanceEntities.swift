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
        transactionId.defaultValue = UUID()
        attributes.append(transactionId)
        
        let amount = NSAttributeDescription()
        amount.name = "amount"
        amount.attributeType = .decimalAttributeType
        amount.isOptional = false
        amount.defaultValue = NSDecimalNumber(value: 0)
        attributes.append(amount)
        
        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false
        type.defaultValue = TransactionType.expense.rawValue
        attributes.append(type)
        
        // 不再使用 categoryId/accountId 属性，仅通过 relationship category/account 关联
        
        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.defaultValue = Date()
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
        tags.valueTransformerName = "NSSecureUnarchiveFromData"
        attributes.append(tags)
        
        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)
        
        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)
        
        // Transaction 与 Category / Account 的关系（对应 Transaction.category / Transaction.account）
        let categoryRelation = NSRelationshipDescription()
        categoryRelation.name = "category"
        categoryRelation.destinationEntity = nil  // 稍后设置，避免循环引用
        categoryRelation.minCount = 0
        categoryRelation.maxCount = 1
        categoryRelation.isOptional = true
        categoryRelation.deleteRule = .nullifyDeleteRule

        let accountRelation = NSRelationshipDescription()
        accountRelation.name = "account"
        accountRelation.destinationEntity = nil
        accountRelation.minCount = 0
        accountRelation.maxCount = 1
        accountRelation.isOptional = true
        accountRelation.deleteRule = .nullifyDeleteRule
        
        // 分期记账字段
        let installmentGroupId = NSAttributeDescription()
        installmentGroupId.name = "installmentGroupId"
        installmentGroupId.attributeType = .UUIDAttributeType
        installmentGroupId.isOptional = true
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

        // AI 来源标记
        let isAICreated = NSAttributeDescription()
        isAICreated.name = "isAICreated"
        isAICreated.attributeType = .booleanAttributeType
        isAICreated.isOptional = false
        isAICreated.defaultValue = false
        attributes.append(isAICreated)

        // AI 确认流程来源标记（对账用，详见 Transaction.aiSourceMessageId 注释）
        let aiSourceMessageId = NSAttributeDescription()
        aiSourceMessageId.name = "aiSourceMessageId"
        aiSourceMessageId.attributeType = .stringAttributeType
        aiSourceMessageId.isOptional = true
        attributes.append(aiSourceMessageId)

        let aiSourceItemId = NSAttributeDescription()
        aiSourceItemId.name = "aiSourceItemId"
        aiSourceItemId.attributeType = .stringAttributeType
        aiSourceItemId.isOptional = true
        attributes.append(aiSourceItemId)

        let aiCandidate = NSAttributeDescription()
        aiCandidate.name = "aiCandidate"
        aiCandidate.attributeType = .stringAttributeType
        aiCandidate.isOptional = true
        attributes.append(aiCandidate)

        let spendingProjectId = NSAttributeDescription()
        spendingProjectId.name = "spendingProjectId"
        spendingProjectId.attributeType = .UUIDAttributeType
        spendingProjectId.isOptional = true
        attributes.append(spendingProjectId)

        let projectPostingState = NSAttributeDescription()
        projectPostingState.name = "projectPostingState"
        projectPostingState.attributeType = .stringAttributeType
        projectPostingState.isOptional = true
        attributes.append(projectPostingState)

        // 导入追踪字段（用于去重 + 按批次撤回）
        let importBatchId = NSAttributeDescription()
        importBatchId.name = "importBatchId"
        importBatchId.attributeType = .UUIDAttributeType
        importBatchId.isOptional = true
        attributes.append(importBatchId)

        let importFingerprint = NSAttributeDescription()
        importFingerprint.name = "importFingerprint"
        importFingerprint.attributeType = .stringAttributeType
        importFingerprint.isOptional = true
        attributes.append(importFingerprint)

        // 导入时的 updatedAt 快照，撤回时用于判断用户是否编辑过此交易
        let importOriginalUpdatedAt = NSAttributeDescription()
        importOriginalUpdatedAt.name = "importOriginalUpdatedAt"
        importOriginalUpdatedAt.attributeType = .dateAttributeType
        importOriginalUpdatedAt.isOptional = true
        attributes.append(importOriginalUpdatedAt)

        // 账单导入来源与原始单号（账单智能导入：筛选/对账 + 同源防重）
        let importSource = NSAttributeDescription()
        importSource.name = "importSource"
        importSource.attributeType = .stringAttributeType
        importSource.isOptional = true
        attributes.append(importSource)

        let importSourceRef = NSAttributeDescription()
        importSourceRef.name = "importSourceRef"
        importSourceRef.attributeType = .stringAttributeType
        importSourceRef.isOptional = true
        attributes.append(importSourceRef)

        let transactionSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: transactionSoftDelete.attributes)

        transactionEntity.properties = attributes + [categoryRelation, accountRelation]
        CoreDataStack.applyIndexes(to: transactionEntity, on: ["id": transactionId, "type": type, "date": date, "installmentGroupId": installmentGroupId, "spendingProjectId": spendingProjectId, "projectPostingState": projectPostingState, "importBatchId": importBatchId, "importFingerprint": importFingerprint, "importSourceRef": importSourceRef, "deletedAt": transactionSoftDelete.deletedAt, "deletedBatchId": transactionSoftDelete.deletedBatchId])
        
        // MARK: - Category Entity
        let categoryEntity = NSEntityDescription()
        categoryEntity.name = "Category"
        categoryEntity.managedObjectClassName = "Category"
        
        var categoryAttributes: [NSAttributeDescription] = []
        
        let categoryIdAttr = NSAttributeDescription()
        categoryIdAttr.name = "id"
        categoryIdAttr.attributeType = .UUIDAttributeType
        categoryIdAttr.isOptional = false
        categoryIdAttr.defaultValue = UUID()
        categoryAttributes.append(categoryIdAttr)
        
        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""
        categoryAttributes.append(name)
        
        let icon = NSAttributeDescription()
        icon.name = "icon"
        icon.attributeType = .stringAttributeType
        icon.isOptional = false
        icon.defaultValue = "questionmark.circle"
        categoryAttributes.append(icon)
        
        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = false
        color.defaultValue = "#64748B"
        categoryAttributes.append(color)
        
        let categoryType = NSAttributeDescription()
        categoryType.name = "type"
        categoryType.attributeType = .stringAttributeType
        categoryType.isOptional = false
        categoryType.defaultValue = TransactionType.expense.rawValue
        categoryAttributes.append(categoryType)
        
        let isDefault = NSAttributeDescription()
        isDefault.name = "isDefault"
        isDefault.attributeType = .booleanAttributeType
        isDefault.isOptional = false
        isDefault.defaultValue = false
        categoryAttributes.append(isDefault)
        
        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = 0
        categoryAttributes.append(sortOrder)
        
        // 父分类 ID（用于二级分类层级关系）
        // 一级分类的 parentId 为 nil，二级分类通过此字段指向其一级分类
        let parentId = NSAttributeDescription()
        parentId.name = "parentId"
        parentId.attributeType = .UUIDAttributeType
        parentId.isOptional = true
        categoryAttributes.append(parentId)

        // 是否为系统内置分类（不可删除/编辑，如"余额调整"）
        let isSystem = NSAttributeDescription()
        isSystem.name = "isSystem"
        isSystem.attributeType = .booleanAttributeType
        isSystem.isOptional = false
        isSystem.defaultValue = false
        categoryAttributes.append(isSystem)

        // 导入批次 ID：标记由某次导入自动创建的分类，撤回时据此判断可否删除
        let categoryImportBatchId = NSAttributeDescription()
        categoryImportBatchId.name = "importBatchId"
        categoryImportBatchId.attributeType = .UUIDAttributeType
        categoryImportBatchId.isOptional = true
        categoryAttributes.append(categoryImportBatchId)

        // Category → Transaction 反向关系（to-many）
        let categoryTransactionsRelation = NSRelationshipDescription()
        categoryTransactionsRelation.name = "transactions"
        categoryTransactionsRelation.destinationEntity = nil  // 稍后设置
        categoryTransactionsRelation.minCount = 0
        categoryTransactionsRelation.maxCount = 0  // 无上限（to-many）
        categoryTransactionsRelation.isOptional = true
        categoryTransactionsRelation.deleteRule = .nullifyDeleteRule

        let categorySoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        categoryAttributes.append(contentsOf: categorySoftDelete.attributes)

        categoryEntity.properties = categoryAttributes + [categoryTransactionsRelation]
        CoreDataStack.applyIndexes(to: categoryEntity, on: ["id": categoryIdAttr, "type": categoryType, "isDefault": isDefault, "sortOrder": sortOrder, "parentId": parentId, "importBatchId": categoryImportBatchId, "deletedAt": categorySoftDelete.deletedAt, "deletedBatchId": categorySoftDelete.deletedBatchId])

        // MARK: - Account Entity
        let accountEntity = NSEntityDescription()
        accountEntity.name = "Account"
        accountEntity.managedObjectClassName = "Account"
        
        var accountAttributes: [NSAttributeDescription] = []
        
        let accountIdAttr = NSAttributeDescription()
        accountIdAttr.name = "id"
        accountIdAttr.attributeType = .UUIDAttributeType
        accountIdAttr.isOptional = false
        accountIdAttr.defaultValue = UUID()
        accountAttributes.append(accountIdAttr)
        
        let accountName = NSAttributeDescription()
        accountName.name = "name"
        accountName.attributeType = .stringAttributeType
        accountName.isOptional = false
        accountName.defaultValue = ""
        accountAttributes.append(accountName)
        
        let accountType = NSAttributeDescription()
        accountType.name = "type"
        accountType.attributeType = .stringAttributeType
        accountType.isOptional = false
        accountType.defaultValue = AccountType.cash.rawValue
        accountAttributes.append(accountType)
        
        let accountIsDefault = NSAttributeDescription()
        accountIsDefault.name = "isDefault"
        accountIsDefault.attributeType = .booleanAttributeType
        accountIsDefault.isOptional = false
        accountIsDefault.defaultValue = false
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

        // 信用卡账单日（每月几号出账单，1-31），仅信用卡类型使用
        let accountBillingDay = NSAttributeDescription()
        accountBillingDay.name = "billingDay"
        accountBillingDay.attributeType = .integer16AttributeType
        accountBillingDay.isOptional = true
        accountAttributes.append(accountBillingDay)

        // 信用卡还款日（每月几号前还清，1-31），仅信用卡类型使用
        let accountDueDay = NSAttributeDescription()
        accountDueDay.name = "dueDay"
        accountDueDay.attributeType = .integer16AttributeType
        accountDueDay.isOptional = true
        accountAttributes.append(accountDueDay)

        // 信用卡额度（可选），仅信用卡类型使用
        let accountCreditLimit = NSAttributeDescription()
        accountCreditLimit.name = "creditLimit"
        accountCreditLimit.attributeType = .decimalAttributeType
        accountCreditLimit.isOptional = true
        accountAttributes.append(accountCreditLimit)

        // 导入批次 ID：标记由某次导入自动创建的账户，撤回时据此判断可否删除
        let accountImportBatchId = NSAttributeDescription()
        accountImportBatchId.name = "importBatchId"
        accountImportBatchId.attributeType = .UUIDAttributeType
        accountImportBatchId.isOptional = true
        accountAttributes.append(accountImportBatchId)

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

        // Account → Transaction 反向关系（to-many）
        let accountTransactionsRelation = NSRelationshipDescription()
        accountTransactionsRelation.name = "transactions"
        accountTransactionsRelation.destinationEntity = nil  // 稍后设置
        accountTransactionsRelation.minCount = 0
        accountTransactionsRelation.maxCount = 0  // 无上限（to-many）
        accountTransactionsRelation.isOptional = true
        accountTransactionsRelation.deleteRule = .nullifyDeleteRule

        let accountSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        accountAttributes.append(contentsOf: accountSoftDelete.attributes)

        accountEntity.properties = accountAttributes + [accountTransactionsRelation]
        CoreDataStack.applyIndexes(to: accountEntity, on: ["id": accountIdAttr, "type": accountType, "isDefault": accountIsDefault, "sortOrder": accountSortOrder, "importBatchId": accountImportBatchId, "deletedAt": accountSoftDelete.deletedAt, "deletedBatchId": accountSoftDelete.deletedBatchId])

        // 绑定 Transaction 关系的目标实体（需在 Category/Account 创建后设置）
        categoryRelation.destinationEntity = categoryEntity
        accountRelation.destinationEntity = accountEntity

        // 绑定反向关系的目标实体
        categoryTransactionsRelation.destinationEntity = transactionEntity
        accountTransactionsRelation.destinationEntity = transactionEntity

        // 双向关系互相引用
        categoryRelation.inverseRelationship = categoryTransactionsRelation
        categoryTransactionsRelation.inverseRelationship = categoryRelation
        accountRelation.inverseRelationship = accountTransactionsRelation
        accountTransactionsRelation.inverseRelationship = accountRelation
        
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
        iconId.defaultValue = ""
        homeIconAttributes.append(iconId)
        
        // 排序顺序（0-based，数字越小越靠前）
        let iconSortOrder = NSAttributeDescription()
        iconSortOrder.name = "sortOrder"
        iconSortOrder.attributeType = .integer16AttributeType
        iconSortOrder.isOptional = false
        iconSortOrder.defaultValue = 0
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
        iconCreatedAt.defaultValue = Date()
        homeIconAttributes.append(iconCreatedAt)
        
        // 更新时间
        let iconUpdatedAt = NSAttributeDescription()
        iconUpdatedAt.name = "updatedAt"
        iconUpdatedAt.attributeType = .dateAttributeType
        iconUpdatedAt.isOptional = false
        iconUpdatedAt.defaultValue = Date()
        homeIconAttributes.append(iconUpdatedAt)
        
        homeIconConfigEntity.properties = homeIconAttributes
        CoreDataStack.applyIndexes(to: homeIconConfigEntity, on: ["iconId": iconId, "sortOrder": iconSortOrder])

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
        budgetId.defaultValue = UUID()
        budgetAttributes.append(budgetId)

        // 所属账户 ID（轻量 UUID 引用，非 Relationship）
        let budgetAccountId = NSAttributeDescription()
        budgetAccountId.name = "accountId"
        budgetAccountId.attributeType = .UUIDAttributeType
        budgetAccountId.isOptional = false
        budgetAccountId.defaultValue = UUID()
        budgetAttributes.append(budgetAccountId)

        // 分类 ID（nil=总预算，非nil=分类预算 Phase 2）
        let budgetCategoryId = NSAttributeDescription()
        budgetCategoryId.name = "categoryId"
        budgetCategoryId.attributeType = .UUIDAttributeType
        budgetCategoryId.isOptional = true
        budgetAttributes.append(budgetCategoryId)

        // 预算金额
        let budgetAmount = NSAttributeDescription()
        budgetAmount.name = "amount"
        budgetAmount.attributeType = .decimalAttributeType
        budgetAmount.isOptional = false
        budgetAmount.defaultValue = NSDecimalNumber(value: 0)
        budgetAttributes.append(budgetAmount)

        // 预算周期（BudgetPeriod.rawValue: week/month/year）
        let budgetPeriod = NSAttributeDescription()
        budgetPeriod.name = "period"
        budgetPeriod.attributeType = .stringAttributeType
        budgetPeriod.isOptional = false
        budgetPeriod.defaultValue = BudgetPeriod.month.rawValue
        budgetAttributes.append(budgetPeriod)

        // 预算起始日期
        let budgetStartDate = NSAttributeDescription()
        budgetStartDate.name = "startDate"
        budgetStartDate.attributeType = .dateAttributeType
        budgetStartDate.isOptional = false
        budgetStartDate.defaultValue = Date()
        budgetAttributes.append(budgetStartDate)

        let budgetCreatedAt = NSAttributeDescription()
        budgetCreatedAt.name = "createdAt"
        budgetCreatedAt.attributeType = .dateAttributeType
        budgetCreatedAt.isOptional = false
        budgetCreatedAt.defaultValue = Date()
        budgetAttributes.append(budgetCreatedAt)

        let budgetUpdatedAt = NSAttributeDescription()
        budgetUpdatedAt.name = "updatedAt"
        budgetUpdatedAt.attributeType = .dateAttributeType
        budgetUpdatedAt.isOptional = false
        budgetUpdatedAt.defaultValue = Date()
        budgetAttributes.append(budgetUpdatedAt)

        let budgetSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        budgetAttributes.append(contentsOf: budgetSoftDelete.attributes)

        budgetEntity.properties = budgetAttributes
        CoreDataStack.applyIndexes(to: budgetEntity, on: ["id": budgetId, "accountId": budgetAccountId, "categoryId": budgetCategoryId, "period": budgetPeriod, "deletedAt": budgetSoftDelete.deletedAt, "deletedBatchId": budgetSoftDelete.deletedBatchId])

        // MARK: - Spending Project Entity
        let spendingProjectEntity = NSEntityDescription()
        spendingProjectEntity.name = "SpendingProject"
        spendingProjectEntity.managedObjectClassName = "SpendingProject"

        func projectAttribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            attribute.defaultValue = defaultValue
            return attribute
        }

        let projectAttributes: [NSAttributeDescription] = [
            projectAttribute("id", .UUIDAttributeType, defaultValue: UUID()),
            projectAttribute("name", .stringAttributeType, defaultValue: ""),
            projectAttribute("kind", .stringAttributeType, defaultValue: "oneOff"),
            projectAttribute("amount", .decimalAttributeType, defaultValue: NSDecimalNumber(value: 0)),
            // 仅用于把旧版项目总额迁移为每期金额；新版固定写 perOccurrence。
            projectAttribute("amountMode", .stringAttributeType, optional: true),
            // 保留旧字段以兼容已经安装过中间版本的数据库，不再参与业务逻辑。
            projectAttribute("paymentMode", .stringAttributeType, optional: true),
            projectAttribute("frequency", .stringAttributeType, optional: true),
            projectAttribute("startDate", .dateAttributeType, defaultValue: Date()),
            projectAttribute("endDate", .dateAttributeType, optional: true),
            projectAttribute("maxOccurrences", .integer32AttributeType, defaultValue: 0),
            projectAttribute("occurrencesGenerated", .integer32AttributeType, defaultValue: 0),
            projectAttribute("plannedLifespanDays", .integer32AttributeType, defaultValue: 0),
            projectAttribute("nextOccurrenceDate", .dateAttributeType, optional: true),
            projectAttribute("isPaused", .booleanAttributeType, defaultValue: false),
            projectAttribute("autoGenerateTransaction", .booleanAttributeType, defaultValue: true),
            projectAttribute("usageCount", .integer32AttributeType, defaultValue: 0),
            projectAttribute("usageDayCount", .integer32AttributeType, defaultValue: 0),
            projectAttribute("lastUsedDate", .dateAttributeType, optional: true),
            projectAttribute("categoryId", .UUIDAttributeType, optional: true),
            projectAttribute("accountId", .UUIDAttributeType, optional: true),
            projectAttribute("createdAt", .dateAttributeType, defaultValue: Date()),
            projectAttribute("updatedAt", .dateAttributeType, defaultValue: Date())
        ]
        let projectSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        spendingProjectEntity.properties = projectAttributes + projectSoftDelete.attributes
        let projectAttributesById: [String: NSAttributeDescription] = Dictionary(
            projectAttributes.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        CoreDataStack.applyIndexes(to: spendingProjectEntity, on: [
            "id": projectAttributesById["id"]!,
            "kind": projectAttributesById["kind"]!,
            "nextOccurrenceDate": projectAttributesById["nextOccurrenceDate"]!,
            "deletedAt": projectSoftDelete.deletedAt,
            "deletedBatchId": projectSoftDelete.deletedBatchId
        ])

        return [transactionEntity, categoryEntity, accountEntity, homeIconConfigEntity, budgetEntity, spendingProjectEntity]
    }

}
