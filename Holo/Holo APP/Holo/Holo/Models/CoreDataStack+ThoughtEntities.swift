//
//  CoreDataStack+ThoughtEntities.swift
//  Holo
//
//  观点相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Thought Entities

    /// 创建观点相关实体（Thought, ThoughtTag, ThoughtReference, ThoughtTagAssignment, Topic）
    nonisolated func createThoughtEntities() -> [NSEntityDescription] {
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
        thoughtId.defaultValue = UUID()
        thoughtAttributes.append(thoughtId)

        let thoughtContent = NSAttributeDescription()
        thoughtContent.name = "content"
        thoughtContent.attributeType = .stringAttributeType
        thoughtContent.isOptional = false
        thoughtContent.defaultValue = ""
        thoughtAttributes.append(thoughtContent)

        let thoughtCreatedAt = NSAttributeDescription()
        thoughtCreatedAt.name = "createdAt"
        thoughtCreatedAt.attributeType = .dateAttributeType
        thoughtCreatedAt.isOptional = false
        thoughtCreatedAt.defaultValue = Date()
        thoughtAttributes.append(thoughtCreatedAt)

        let thoughtUpdatedAt = NSAttributeDescription()
        thoughtUpdatedAt.name = "updatedAt"
        thoughtUpdatedAt.attributeType = .dateAttributeType
        thoughtUpdatedAt.isOptional = false
        thoughtUpdatedAt.defaultValue = Date()
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

        // AI 自动整理状态
        let thoughtOrganizedStatus = NSAttributeDescription()
        thoughtOrganizedStatus.name = "organizedStatus"
        thoughtOrganizedStatus.attributeType = .stringAttributeType
        thoughtOrganizedStatus.isOptional = false
        thoughtOrganizedStatus.defaultValue = "unprocessed"
        thoughtAttributes.append(thoughtOrganizedStatus)

        // 创建该想法的设备 ID
        let thoughtCreatedDeviceId = NSAttributeDescription()
        thoughtCreatedDeviceId.name = "createdDeviceId"
        thoughtCreatedDeviceId.attributeType = .stringAttributeType
        thoughtCreatedDeviceId.isOptional = true
        thoughtAttributes.append(thoughtCreatedDeviceId)

        // AI 整理开始时间（processing 超时恢复）
        let thoughtOrganizationStartedAt = NSAttributeDescription()
        thoughtOrganizationStartedAt.name = "organizationStartedAt"
        thoughtOrganizationStartedAt.attributeType = .dateAttributeType
        thoughtOrganizationStartedAt.isOptional = true
        thoughtAttributes.append(thoughtOrganizationStartedAt)

        // 结构化内容 JSON（含 #/@ Token 的编辑器事实源，可空=纯文本想法）
        let thoughtRichContentJSON = NSAttributeDescription()
        thoughtRichContentJSON.name = "richContentJSON"
        thoughtRichContentJSON.attributeType = .stringAttributeType
        thoughtRichContentJSON.isOptional = true
        thoughtAttributes.append(thoughtRichContentJSON)

        // 首行摘要（@ 引用候选列表标题，保存时派生）
        let thoughtFirstLine = NSAttributeDescription()
        thoughtFirstLine.name = "firstLine"
        thoughtFirstLine.attributeType = .stringAttributeType
        thoughtFirstLine.isOptional = true
        thoughtAttributes.append(thoughtFirstLine)

        // 主题归属置信度：AI 整理写入（0-1），手动移入/用户确认置 1；<0.75 进待确认池
        let thoughtTopicConfidence = NSAttributeDescription()
        thoughtTopicConfidence.name = "topicConfidence"
        thoughtTopicConfidence.attributeType = .doubleAttributeType
        thoughtTopicConfidence.isOptional = false
        thoughtTopicConfidence.defaultValue = 0.0
        thoughtAttributes.append(thoughtTopicConfidence)

        // 主题归属理由（后端 thought_organization v4 已随结果返回，客户端落库供待确认池/详情页展示）
        let thoughtTopicReason = NSAttributeDescription()
        thoughtTopicReason.name = "topicAssignmentReason"
        thoughtTopicReason.attributeType = .stringAttributeType
        thoughtTopicReason.isOptional = true
        thoughtAttributes.append(thoughtTopicReason)

        // MARK: 想法自动整理 V2（2026-09-05 方案 §7.2）索引元数据
        // 发起整理时正文的版本标记（可见纯文本 hash）；响应校验与重跑判定的事实源
        let thoughtIndexRequestedHash = NSAttributeDescription()
        thoughtIndexRequestedHash.name = "indexRequestedHash"
        thoughtIndexRequestedHash.attributeType = .stringAttributeType
        thoughtIndexRequestedHash.isOptional = true
        thoughtAttributes.append(thoughtIndexRequestedHash)

        // 完成标记：本次正文版本的整理已终结（含合法 0 标签），防止每次开 App 重跑
        let thoughtIndexCompletedHash = NSAttributeDescription()
        thoughtIndexCompletedHash.name = "indexCompletedHash"
        thoughtIndexCompletedHash.attributeType = .stringAttributeType
        thoughtIndexCompletedHash.isOptional = true
        thoughtAttributes.append(thoughtIndexCompletedHash)

        // 本次逻辑任务的随机操作 ID（服务端幂等/费用台账对账用）
        let thoughtIndexOperationID = NSAttributeDescription()
        thoughtIndexOperationID.name = "indexOperationID"
        thoughtIndexOperationID.attributeType = .UUIDAttributeType
        thoughtIndexOperationID.isOptional = true
        thoughtAttributes.append(thoughtIndexOperationID)

        // 网络类失败重试计数（每个正文版本最多额外 1 次）
        let thoughtIndexAttemptCount = NSAttributeDescription()
        thoughtIndexAttemptCount.name = "indexAttemptCount"
        thoughtIndexAttemptCount.attributeType = .integer16AttributeType
        thoughtIndexAttemptCount.isOptional = false
        thoughtIndexAttemptCount.defaultValue = 0
        thoughtAttributes.append(thoughtIndexAttemptCount)

        // 下次允许整理的时间（预算窗口/退避，持久化供重启恢复）
        let thoughtIndexNextAttemptAt = NSAttributeDescription()
        thoughtIndexNextAttemptAt.name = "indexNextAttemptAt"
        thoughtIndexNextAttemptAt.attributeType = .dateAttributeType
        thoughtIndexNextAttemptAt.isOptional = true
        thoughtAttributes.append(thoughtIndexNextAttemptAt)

        // 产生结果的引擎版本（thought_index_v2.1）；升级后按版本决定旧结果是否可续用
        let thoughtIndexEngineVersion = NSAttributeDescription()
        thoughtIndexEngineVersion.name = "indexEngineVersion"
        thoughtIndexEngineVersion.attributeType = .stringAttributeType
        thoughtIndexEngineVersion.isOptional = true
        thoughtAttributes.append(thoughtIndexEngineVersion)

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
        thoughtTagId.defaultValue = UUID()
        thoughtTagAttributes.append(thoughtTagId)

        let thoughtTagName = NSAttributeDescription()
        thoughtTagName.name = "name"
        thoughtTagName.attributeType = .stringAttributeType
        thoughtTagName.isOptional = false
        thoughtTagName.defaultValue = ""
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

        // 最近使用时间（# 候选面板「最近使用」排序）
        let thoughtTagLastUsedAt = NSAttributeDescription()
        thoughtTagLastUsedAt.name = "lastUsedAt"
        thoughtTagLastUsedAt.attributeType = .dateAttributeType
        thoughtTagLastUsedAt.isOptional = true
        thoughtTagAttributes.append(thoughtTagLastUsedAt)

        // MARK: 想法自动整理 V2（2026-09-05 方案 §7.2）概念语义层
        // V2 平面展示名；旧 name（可能含"工作/Holo"式路径）保持原值不动
        let thoughtTagSemanticName = NSAttributeDescription()
        thoughtTagSemanticName.name = "semanticName"
        thoughtTagSemanticName.attributeType = .stringAttributeType
        thoughtTagSemanticName.isOptional = true
        thoughtTagAttributes.append(thoughtTagSemanticName)

        // 简短概念边界说明（描述什么算/什么不算，不存某条想法的私人摘要）
        let thoughtTagSemanticDefinition = NSAttributeDescription()
        thoughtTagSemanticDefinition.name = "semanticDefinition"
        thoughtTagSemanticDefinition.attributeType = .stringAttributeType
        thoughtTagSemanticDefinition.isOptional = true
        thoughtTagAttributes.append(thoughtTagSemanticDefinition)

        // 已验证等价表达（JSON 数组，仅 equivalent 别名；不含上位/相关词）
        let thoughtTagAliasesJSON = NSAttributeDescription()
        thoughtTagAliasesJSON.name = "aliasesJSON"
        thoughtTagAliasesJSON.attributeType = .stringAttributeType
        thoughtTagAliasesJSON.isOptional = true
        thoughtTagAttributes.append(thoughtTagAliasesJSON)

        // 词条身份来源：user/auto/provisional/legacy；旧数据按迁移规则回填
        let thoughtTagIndexKind = NSAttributeDescription()
        thoughtTagIndexKind.name = "indexKind"
        thoughtTagIndexKind.attributeType = .stringAttributeType
        thoughtTagIndexKind.isOptional = true
        thoughtTagAttributes.append(thoughtTagIndexKind)

        // 用户命名或明确确认后 AI 不改名
        let thoughtTagNameLocked = NSAttributeDescription()
        thoughtTagNameLocked.name = "nameLockedByUser"
        thoughtTagNameLocked.attributeType = .booleanAttributeType
        thoughtTagNameLocked.isOptional = false
        thoughtTagNameLocked.defaultValue = false
        thoughtTagAttributes.append(thoughtTagNameLocked)

        // 重复自动身份的确定性重定向目标（仅无用户冲突时；读取时解析并防环）
        let thoughtTagMergedInto = NSAttributeDescription()
        thoughtTagMergedInto.name = "mergedIntoTagID"
        thoughtTagMergedInto.attributeType = .UUIDAttributeType
        thoughtTagMergedInto.isOptional = true
        thoughtTagAttributes.append(thoughtTagMergedInto)

        // 用户全局拒绝 AI 自动使用该概念；不自动过期，手动添加不受影响
        let thoughtTagAutoBlocked = NSAttributeDescription()
        thoughtTagAutoBlocked.name = "autoSuggestionBlocked"
        thoughtTagAutoBlocked.attributeType = .booleanAttributeType
        thoughtTagAutoBlocked.isOptional = false
        thoughtTagAutoBlocked.defaultValue = false
        thoughtTagAttributes.append(thoughtTagAutoBlocked)

        // 仅隐藏自动合集浏览入口；不影响打标与标签筛选
        let thoughtTagAutoCollectionHidden = NSAttributeDescription()
        thoughtTagAutoCollectionHidden.name = "autoCollectionHidden"
        thoughtTagAutoCollectionHidden.attributeType = .booleanAttributeType
        thoughtTagAutoCollectionHidden.isOptional = false
        thoughtTagAutoCollectionHidden.defaultValue = false
        thoughtTagAttributes.append(thoughtTagAutoCollectionHidden)

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
        thoughtReferenceId.defaultValue = UUID()
        thoughtReferenceAttributes.append(thoughtReferenceId)

        let thoughtReferenceCreatedAt = NSAttributeDescription()
        thoughtReferenceCreatedAt.name = "createdAt"
        thoughtReferenceCreatedAt.attributeType = .dateAttributeType
        thoughtReferenceCreatedAt.isOptional = false
        thoughtReferenceCreatedAt.defaultValue = Date()
        thoughtReferenceAttributes.append(thoughtReferenceCreatedAt)

        // 插入时目标首行快照（@ 后显示的文字）
        let thoughtReferenceDisplayText = NSAttributeDescription()
        thoughtReferenceDisplayText.name = "displayText"
        thoughtReferenceDisplayText.attributeType = .stringAttributeType
        thoughtReferenceDisplayText.isOptional = true
        thoughtReferenceAttributes.append(thoughtReferenceDisplayText)

        // 插入时目标正文摘要快照（目标删除后展示）
        let thoughtReferenceSnapshot = NSAttributeDescription()
        thoughtReferenceSnapshot.name = "snapshot"
        thoughtReferenceSnapshot.attributeType = .stringAttributeType
        thoughtReferenceSnapshot.isOptional = true
        thoughtReferenceAttributes.append(thoughtReferenceSnapshot)

        // MARK: - ThoughtTagAssignment Entity
        // AI 自动整理 - 标签分配中间实体
        let assignmentEntity = NSEntityDescription()
        assignmentEntity.name = "ThoughtTagAssignment"
        assignmentEntity.managedObjectClassName = "ThoughtTagAssignment"

        var assignmentAttributes: [NSAttributeDescription] = []

        let assignmentId = NSAttributeDescription()
        assignmentId.name = "id"
        assignmentId.attributeType = .UUIDAttributeType
        assignmentId.isOptional = false
        assignmentId.defaultValue = UUID()
        assignmentAttributes.append(assignmentId)

        let assignmentSource = NSAttributeDescription()
        assignmentSource.name = "source"
        assignmentSource.attributeType = .stringAttributeType
        assignmentSource.isOptional = false
        assignmentSource.defaultValue = "ai"
        assignmentAttributes.append(assignmentSource)

        let assignmentConfidence = NSAttributeDescription()
        assignmentConfidence.name = "confidence"
        assignmentConfidence.attributeType = .doubleAttributeType
        assignmentConfidence.isOptional = false
        assignmentConfidence.defaultValue = 1.0
        assignmentAttributes.append(assignmentConfidence)

        let assignmentAssignedAt = NSAttributeDescription()
        assignmentAssignedAt.name = "assignedAt"
        assignmentAssignedAt.attributeType = .dateAttributeType
        assignmentAssignedAt.isOptional = false
        assignmentAssignedAt.defaultValue = Date()
        assignmentAttributes.append(assignmentAssignedAt)

        let assignmentRejectedAt = NSAttributeDescription()
        assignmentRejectedAt.name = "rejectedAt"
        assignmentRejectedAt.attributeType = .dateAttributeType
        assignmentRejectedAt.isOptional = true
        assignmentAttributes.append(assignmentRejectedAt)

        // MARK: 想法自动整理 V2（2026-09-05 方案 §7.2）证据与状态层
        // 2 = 本算法（两阶段+服务端校验）产出并通过客户端复核的自动索引
        let assignmentIndexVersion = NSAttributeDescription()
        assignmentIndexVersion.name = "indexVersion"
        assignmentIndexVersion.attributeType = .integer16AttributeType
        assignmentIndexVersion.isOptional = false
        assignmentIndexVersion.defaultValue = 0
        assignmentAttributes.append(assignmentIndexVersion)

        // 当前关系的原文证据（逐字片段，仅本地/原有同步保存，不写服务器日志）
        let assignmentEvidenceQuote = NSAttributeDescription()
        assignmentEvidenceQuote.name = "evidenceQuote"
        assignmentEvidenceQuote.attributeType = .stringAttributeType
        assignmentEvidenceQuote.isOptional = true
        assignmentAttributes.append(assignmentEvidenceQuote)

        // 产生该关系时的正文版本 hash；与当前正文不符即失效（防旧结果贴新正文）
        let assignmentBasisTextHash = NSAttributeDescription()
        assignmentBasisTextHash.name = "basisTextHash"
        assignmentBasisTextHash.attributeType = .stringAttributeType
        assignmentBasisTextHash.isOptional = true
        assignmentAttributes.append(assignmentBasisTextHash)

        // active/superseded/legacy；拒绝事实继续用 source=rejectedAI 表达
        let assignmentIndexState = NSAttributeDescription()
        assignmentIndexState.name = "indexState"
        assignmentIndexState.attributeType = .stringAttributeType
        assignmentIndexState.isOptional = true
        assignmentAttributes.append(assignmentIndexState)

        // MARK: - Topic Entity
        // AI 自动整理 - 主题实体
        let topicEntity = NSEntityDescription()
        topicEntity.name = "Topic"
        topicEntity.managedObjectClassName = "Topic"

        var topicAttributes: [NSAttributeDescription] = []

        let topicId = NSAttributeDescription()
        topicId.name = "id"
        topicId.attributeType = .UUIDAttributeType
        topicId.isOptional = false
        topicId.defaultValue = UUID()
        topicAttributes.append(topicId)

        let topicTitle = NSAttributeDescription()
        topicTitle.name = "title"
        topicTitle.attributeType = .stringAttributeType
        topicTitle.isOptional = false
        topicTitle.defaultValue = ""
        topicAttributes.append(topicTitle)

        // 主题图标 emoji（知识树卡片/详情页展示；nil 时按标题智能给默认）
        let topicIconEmoji = NSAttributeDescription()
        topicIconEmoji.name = "iconEmoji"
        topicIconEmoji.attributeType = .stringAttributeType
        topicIconEmoji.isOptional = true
        topicAttributes.append(topicIconEmoji)

        let topicSummary = NSAttributeDescription()
        topicSummary.name = "summary"
        topicSummary.attributeType = .stringAttributeType
        topicSummary.isOptional = true
        topicAttributes.append(topicSummary)

        let topicStatus = NSAttributeDescription()
        topicStatus.name = "status"
        topicStatus.attributeType = .stringAttributeType
        topicStatus.isOptional = false
        topicStatus.defaultValue = "candidate"
        topicAttributes.append(topicStatus)

        let topicConfidence = NSAttributeDescription()
        topicConfidence.name = "confidence"
        topicConfidence.attributeType = .doubleAttributeType
        topicConfidence.isOptional = false
        topicConfidence.defaultValue = 0.0
        topicAttributes.append(topicConfidence)

        let topicAssociatedTagNames = NSAttributeDescription()
        topicAssociatedTagNames.name = "associatedTagNames"
        topicAssociatedTagNames.attributeType = .stringAttributeType
        topicAssociatedTagNames.isOptional = true
        topicAttributes.append(topicAssociatedTagNames)

        let topicThoughtCount = NSAttributeDescription()
        topicThoughtCount.name = "thoughtCount"
        topicThoughtCount.attributeType = .integer16AttributeType
        topicThoughtCount.isOptional = false
        topicThoughtCount.defaultValue = 0
        topicAttributes.append(topicThoughtCount)

        let topicCreatedAt = NSAttributeDescription()
        topicCreatedAt.name = "createdAt"
        topicCreatedAt.attributeType = .dateAttributeType
        topicCreatedAt.isOptional = false
        topicCreatedAt.defaultValue = Date()
        topicAttributes.append(topicCreatedAt)

        let topicUpdatedAt = NSAttributeDescription()
        topicUpdatedAt.name = "updatedAt"
        topicUpdatedAt.attributeType = .dateAttributeType
        topicUpdatedAt.isOptional = false
        topicUpdatedAt.defaultValue = Date()
        topicAttributes.append(topicUpdatedAt)

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
        referenceSourceRelation.minCount = 0
        referenceSourceRelation.maxCount = 1
        referenceSourceRelation.deleteRule = .nullifyDeleteRule
        referenceSourceRelation.isOptional = true

        // ThoughtReference → Thought（被引用方）
        let referenceTargetRelation = NSRelationshipDescription()
        referenceTargetRelation.name = "targetThought"
        referenceTargetRelation.destinationEntity = thoughtEntity
        referenceTargetRelation.minCount = 0
        referenceTargetRelation.maxCount = 1
        referenceTargetRelation.deleteRule = .nullifyDeleteRule
        referenceTargetRelation.isOptional = true

        // 设置双向关系
        thoughtReferencesRelation.inverseRelationship = referenceSourceRelation
        referenceSourceRelation.inverseRelationship = thoughtReferencesRelation

        thoughtReferencedByRelation.inverseRelationship = referenceTargetRelation
        referenceTargetRelation.inverseRelationship = thoughtReferencedByRelation

        // Thought → ThoughtTagAssignment（一对多，cascade）
        let thoughtAssignmentsRelation = NSRelationshipDescription()
        thoughtAssignmentsRelation.name = "tagAssignments"
        thoughtAssignmentsRelation.destinationEntity = assignmentEntity
        thoughtAssignmentsRelation.minCount = 0
        thoughtAssignmentsRelation.maxCount = 0
        thoughtAssignmentsRelation.deleteRule = .cascadeDeleteRule
        thoughtAssignmentsRelation.isOptional = true

        let assignmentThoughtRelation = NSRelationshipDescription()
        assignmentThoughtRelation.name = "thought"
        assignmentThoughtRelation.destinationEntity = thoughtEntity
        assignmentThoughtRelation.minCount = 0
        assignmentThoughtRelation.maxCount = 1
        assignmentThoughtRelation.deleteRule = .nullifyDeleteRule
        assignmentThoughtRelation.isOptional = true

        thoughtAssignmentsRelation.inverseRelationship = assignmentThoughtRelation
        assignmentThoughtRelation.inverseRelationship = thoughtAssignmentsRelation

        // Thought ↔ Topic（多对多，nullify）
        let thoughtTopicsRelation = NSRelationshipDescription()
        thoughtTopicsRelation.name = "topics"
        thoughtTopicsRelation.destinationEntity = topicEntity
        thoughtTopicsRelation.minCount = 0
        thoughtTopicsRelation.maxCount = 0
        thoughtTopicsRelation.deleteRule = .nullifyDeleteRule
        thoughtTopicsRelation.isOptional = true

        let topicThoughtsRelation = NSRelationshipDescription()
        topicThoughtsRelation.name = "thoughts"
        topicThoughtsRelation.destinationEntity = thoughtEntity
        topicThoughtsRelation.minCount = 0
        topicThoughtsRelation.maxCount = 0
        topicThoughtsRelation.deleteRule = .nullifyDeleteRule
        topicThoughtsRelation.isOptional = true

        thoughtTopicsRelation.inverseRelationship = topicThoughtsRelation
        topicThoughtsRelation.inverseRelationship = thoughtTopicsRelation

        // ThoughtTag → ThoughtTagAssignment（一对多，cascade）
        let tagAssignmentsRelation = NSRelationshipDescription()
        tagAssignmentsRelation.name = "assignments"
        tagAssignmentsRelation.destinationEntity = assignmentEntity
        tagAssignmentsRelation.minCount = 0
        tagAssignmentsRelation.maxCount = 0
        tagAssignmentsRelation.deleteRule = .cascadeDeleteRule
        tagAssignmentsRelation.isOptional = true

        let assignmentTagRelation = NSRelationshipDescription()
        assignmentTagRelation.name = "tag"
        assignmentTagRelation.destinationEntity = thoughtTagEntity
        assignmentTagRelation.minCount = 0
        assignmentTagRelation.maxCount = 1
        assignmentTagRelation.deleteRule = .nullifyDeleteRule
        assignmentTagRelation.isOptional = true

        tagAssignmentsRelation.inverseRelationship = assignmentTagRelation
        assignmentTagRelation.inverseRelationship = tagAssignmentsRelation

        // ThoughtTag ↔ Topic（多对多，nullify）
        let tagAssociatedTopicsRelation = NSRelationshipDescription()
        tagAssociatedTopicsRelation.name = "associatedTopics"
        tagAssociatedTopicsRelation.destinationEntity = topicEntity
        tagAssociatedTopicsRelation.minCount = 0
        tagAssociatedTopicsRelation.maxCount = 0
        tagAssociatedTopicsRelation.deleteRule = .nullifyDeleteRule
        tagAssociatedTopicsRelation.isOptional = true

        let topicAssociatedTagsRelation = NSRelationshipDescription()
        topicAssociatedTagsRelation.name = "associatedTags"
        topicAssociatedTagsRelation.destinationEntity = thoughtTagEntity
        topicAssociatedTagsRelation.minCount = 0
        topicAssociatedTagsRelation.maxCount = 0
        topicAssociatedTagsRelation.deleteRule = .nullifyDeleteRule
        topicAssociatedTagsRelation.isOptional = true

        tagAssociatedTopicsRelation.inverseRelationship = topicAssociatedTagsRelation
        topicAssociatedTagsRelation.inverseRelationship = tagAssociatedTopicsRelation

        // Topic 自引用：mergedToTopic（多对一）/ mergedFromTopics（一对多）
        let topicMergedToRelation = NSRelationshipDescription()
        topicMergedToRelation.name = "mergedToTopic"
        topicMergedToRelation.destinationEntity = topicEntity
        topicMergedToRelation.minCount = 0
        topicMergedToRelation.maxCount = 1
        topicMergedToRelation.deleteRule = .nullifyDeleteRule
        topicMergedToRelation.isOptional = true

        let topicMergedFromRelation = NSRelationshipDescription()
        topicMergedFromRelation.name = "mergedFromTopics"
        topicMergedFromRelation.destinationEntity = topicEntity
        topicMergedFromRelation.minCount = 0
        topicMergedFromRelation.maxCount = 0
        topicMergedFromRelation.deleteRule = .nullifyDeleteRule
        topicMergedFromRelation.isOptional = true

        topicMergedToRelation.inverseRelationship = topicMergedFromRelation
        topicMergedFromRelation.inverseRelationship = topicMergedToRelation

        // MARK: - ThoughtAttachment Entity
        // 想法模块 - 图片附件实体
        let thoughtAttachmentEntity = NSEntityDescription()
        thoughtAttachmentEntity.name = "ThoughtAttachment"
        thoughtAttachmentEntity.managedObjectClassName = "ThoughtAttachment"

        var thoughtAttachmentAttributes: [NSAttributeDescription] = []

        let taId = NSAttributeDescription()
        taId.name = "id"
        taId.attributeType = .UUIDAttributeType
        taId.isOptional = false
        taId.defaultValue = UUID()
        thoughtAttachmentAttributes.append(taId)

        let taFileName = NSAttributeDescription()
        taFileName.name = "fileName"
        taFileName.attributeType = .stringAttributeType
        taFileName.isOptional = false
        taFileName.defaultValue = ""
        thoughtAttachmentAttributes.append(taFileName)

        let taThumbnailFileName = NSAttributeDescription()
        taThumbnailFileName.name = "thumbnailFileName"
        taThumbnailFileName.attributeType = .stringAttributeType
        taThumbnailFileName.isOptional = false
        taThumbnailFileName.defaultValue = ""
        thoughtAttachmentAttributes.append(taThumbnailFileName)

        let taSortOrder = NSAttributeDescription()
        taSortOrder.name = "sortOrder"
        taSortOrder.attributeType = .integer16AttributeType
        taSortOrder.isOptional = false
        taSortOrder.defaultValue = 0
        thoughtAttachmentAttributes.append(taSortOrder)

        let taSourceType = NSAttributeDescription()
        taSourceType.name = "sourceType"
        taSourceType.attributeType = .stringAttributeType
        taSourceType.isOptional = false
        taSourceType.defaultValue = "photoLibrary"
        thoughtAttachmentAttributes.append(taSourceType)

        let taCreatedAt = NSAttributeDescription()
        taCreatedAt.name = "createdAt"
        taCreatedAt.attributeType = .dateAttributeType
        taCreatedAt.isOptional = false
        taCreatedAt.defaultValue = Date()
        thoughtAttachmentAttributes.append(taCreatedAt)

        let taImageData = NSAttributeDescription()
        taImageData.name = "imageData"
        taImageData.attributeType = .binaryDataAttributeType
        taImageData.isOptional = true
        thoughtAttachmentAttributes.append(taImageData)

        let taThumbnailData = NSAttributeDescription()
        taThumbnailData.name = "thumbnailData"
        taThumbnailData.attributeType = .binaryDataAttributeType
        taThumbnailData.isOptional = true
        thoughtAttachmentAttributes.append(taThumbnailData)

        // MARK: - ThoughtAttachment Relationships

        // Thought → ThoughtAttachment（一对多，cascade）
        let thoughtAttachmentsRelation = NSRelationshipDescription()
        thoughtAttachmentsRelation.name = "attachments"
        thoughtAttachmentsRelation.destinationEntity = thoughtAttachmentEntity
        thoughtAttachmentsRelation.minCount = 0
        thoughtAttachmentsRelation.maxCount = 0
        thoughtAttachmentsRelation.deleteRule = .cascadeDeleteRule
        thoughtAttachmentsRelation.isOptional = true

        // ThoughtAttachment → Thought（多对一，nullify）
        let attachmentThoughtRelation = NSRelationshipDescription()
        attachmentThoughtRelation.name = "thought"
        attachmentThoughtRelation.destinationEntity = thoughtEntity
        attachmentThoughtRelation.minCount = 0
        attachmentThoughtRelation.maxCount = 1
        attachmentThoughtRelation.deleteRule = .nullifyDeleteRule
        attachmentThoughtRelation.isOptional = true

        thoughtAttachmentsRelation.inverseRelationship = attachmentThoughtRelation
        attachmentThoughtRelation.inverseRelationship = thoughtAttachmentsRelation

        // 统一软删除标记（Thought/ThoughtTag/Topic 为清空批次的顶层实体；
        // Reference/Assignment/Attachment 跟随 Thought 生命周期，无需独立标记）
        let thoughtSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        thoughtAttributes.append(contentsOf: thoughtSoftDelete.attributes)
        let thoughtTagSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        thoughtTagAttributes.append(contentsOf: thoughtTagSoftDelete.attributes)
        let topicSoftDelete = CoreDataStack.makeSoftDeleteAttributes()
        topicAttributes.append(contentsOf: topicSoftDelete.attributes)

        // 将属性和关系添加到实体
        thoughtEntity.properties = thoughtAttributes + [
            thoughtTagsRelation,
            thoughtReferencesRelation,
            thoughtReferencedByRelation,
            thoughtAssignmentsRelation,
            thoughtTopicsRelation,
            thoughtAttachmentsRelation
        ]
        CoreDataStack.applyIndexes(to: thoughtEntity, on: ["id": thoughtId, "deletedAt": thoughtSoftDelete.deletedAt, "deletedBatchId": thoughtSoftDelete.deletedBatchId])
        thoughtTagEntity.properties = thoughtTagAttributes + [
            tagThoughtsRelation,
            tagAssignmentsRelation,
            tagAssociatedTopicsRelation
        ]
        CoreDataStack.applyIndexes(to: thoughtTagEntity, on: ["id": thoughtTagId, "deletedAt": thoughtTagSoftDelete.deletedAt, "deletedBatchId": thoughtTagSoftDelete.deletedBatchId])
        thoughtReferenceEntity.properties = thoughtReferenceAttributes + [
            referenceSourceRelation,
            referenceTargetRelation
        ]
        CoreDataStack.applyIndexes(to: thoughtReferenceEntity, on: ["id": thoughtReferenceId])
        assignmentEntity.properties = assignmentAttributes + [
            assignmentThoughtRelation,
            assignmentTagRelation
        ]
        CoreDataStack.applyIndexes(to: assignmentEntity, on: ["id": assignmentId])
        topicEntity.properties = topicAttributes + [
            topicThoughtsRelation,
            topicAssociatedTagsRelation,
            topicMergedToRelation,
            topicMergedFromRelation
        ]
        CoreDataStack.applyIndexes(to: topicEntity, on: ["id": topicId, "deletedAt": topicSoftDelete.deletedAt, "deletedBatchId": topicSoftDelete.deletedBatchId])
        thoughtAttachmentEntity.properties = thoughtAttachmentAttributes + [
            attachmentThoughtRelation
        ]
        CoreDataStack.applyIndexes(to: thoughtAttachmentEntity, on: ["id": taId])

        // MARK: - ThoughtTagConvergenceRejection Entity
        // P2.5 - 主题归并建议级拒绝（幂等键=主题名+来源词集合，无关系，独立实体，随 iCloud 同步）
        let convergenceRejectionEntity = NSEntityDescription()
        convergenceRejectionEntity.name = "ThoughtTagConvergenceRejection"
        convergenceRejectionEntity.managedObjectClassName = "ThoughtTagConvergenceRejection"

        var convergenceRejectionAttributes: [NSAttributeDescription] = []

        let crId = NSAttributeDescription()
        crId.name = "id"
        crId.attributeType = .UUIDAttributeType
        crId.isOptional = false
        crId.defaultValue = UUID()
        convergenceRejectionAttributes.append(crId)

        let crKey = NSAttributeDescription()
        crKey.name = "suggestionKey"
        crKey.attributeType = .stringAttributeType
        crKey.isOptional = false
        crKey.defaultValue = ""
        convergenceRejectionAttributes.append(crKey)

        let crTopicTitle = NSAttributeDescription()
        crTopicTitle.name = "topicTitle"
        crTopicTitle.attributeType = .stringAttributeType
        crTopicTitle.isOptional = false
        crTopicTitle.defaultValue = ""
        convergenceRejectionAttributes.append(crTopicTitle)

        let crSourceTerms = NSAttributeDescription()
        crSourceTerms.name = "sourceTermsText"
        crSourceTerms.attributeType = .stringAttributeType
        crSourceTerms.isOptional = true
        convergenceRejectionAttributes.append(crSourceTerms)

        let crRejectedAt = NSAttributeDescription()
        crRejectedAt.name = "rejectedAt"
        crRejectedAt.attributeType = .dateAttributeType
        crRejectedAt.isOptional = false
        crRejectedAt.defaultValue = Date()
        convergenceRejectionAttributes.append(crRejectedAt)

        let crExpiresAt = NSAttributeDescription()
        crExpiresAt.name = "expiresAt"
        crExpiresAt.attributeType = .dateAttributeType
        crExpiresAt.isOptional = false
        crExpiresAt.defaultValue = Date()
        convergenceRejectionAttributes.append(crExpiresAt)

        let crCreatedAt = NSAttributeDescription()
        crCreatedAt.name = "createdAt"
        crCreatedAt.attributeType = .dateAttributeType
        crCreatedAt.isOptional = false
        crCreatedAt.defaultValue = Date()
        convergenceRejectionAttributes.append(crCreatedAt)

        convergenceRejectionEntity.properties = convergenceRejectionAttributes
        CoreDataStack.applyIndexes(to: convergenceRejectionEntity, on: ["id": crId, "suggestionKey": crKey])

        return [thoughtEntity, thoughtTagEntity, thoughtReferenceEntity, assignmentEntity, topicEntity, thoughtAttachmentEntity, convergenceRejectionEntity]
    }

}
