//
//  CoreDataStack+TaskExecutionEntities.swift
//  Holo
//
//  任务「分步推进」三实体程序化定义（2026-09-25 实施规格 §7.2）
//
//  - HoloTaskExecutionRevision：已采纳的不可变计划版本（历史不覆盖）
//  - HoloTaskExecutionStep：动作内容与执行事实（完成/等待/停留记录）
//  - HoloTaskExecutionReceipt：命令回执与审计（幂等、解释、安全撤回）
//
//  设计约束与 Matter 四实体同构（ADR-02）：
//  - 全部 ID 逻辑外键，无跨域 relationship（CloudKit 不支持唯一约束/跨实体强一致）
//  - 非空属性带兼容默认值（CloudKit 要求；语义上由 HoloTaskExecutionService 显式赋值）
//  - 未知 enum raw / 损坏 JSON 由类型化访问器兜底，不启动崩溃
//  - 生成步骤绝不复用 CheckItem：CheckItem 的父子级联语义保持原样（规格 §2 技术判断）
//

import CoreData

/// 分步执行 schema 默认值占位（CloudKit 要求非可选属性有默认值）
nonisolated enum TaskExecutionSchemaDefaults {
    nonisolated static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

nonisolated extension CoreDataStack {

    nonisolated func createTaskExecutionEntities() -> [NSEntityDescription] {
        let revision = makeTaskExecutionRevisionEntity()
        let step = makeTaskExecutionStepEntity()
        let receipt = makeTaskExecutionReceiptEntity()
        return [revision, step, receipt]
    }

    // MARK: - HoloTaskExecutionRevision

    private func makeTaskExecutionRevisionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloTaskExecutionRevision"
        entity.managedObjectClassName = "HoloTaskExecutionRevision"

        var attributes: [NSAttributeDescription] = []
        @discardableResult
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let value { a.defaultValue = value }
            attributes.append(a)
            return a
        }

        let id = attr("id", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        let taskID = attr("taskID", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        // 来源 Matter（规格 §7.2：originMatterID 只是来源；执行计划归 taskID，解绑不误删）
        attr("originMatterID", .UUIDAttributeType, optional: true)
        // 正常一个父版本；并发分叉解决时可有多个（JSON 数组，规格 §9.1）
        attr("parentRevisionIDsJSON", .stringAttributeType, optional: true)
        // 采纳幂等键（规格 §7.5：同 operationID 重放不得生成第二份版本）
        let operationID = attr("operationID", .stringAttributeType, optional: false, default: "")
        attr("schemaVersion", .integer16AttributeType, optional: false, default: 1)
        // 采纳时的候选输入快照 hash（过期判定与迟到候选拒绝）
        attr("sourceFingerprint", .stringAttributeType, optional: false, default: "")
        // 结果契约：摘要、requirement、核验问题、契约依据指纹、已确认范围变化
        attr("outcomeContractJSON", .stringAttributeType, optional: true)
        // 拓扑：节点 ID、分组、稳定顺序、必要/可选、依赖、覆盖关系（不存完成状态）
        attr("topologyJSON", .stringAttributeType, optional: true)
        attr("acceptedSourceRaw", .stringAttributeType, optional: false, default: HoloTaskExecutionPlanSource.userAcceptedAI.rawValue)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "taskID": taskID,
            "operationID": operationID,
        ])
        return entity
    }

    // MARK: - HoloTaskExecutionStep

    private func makeTaskExecutionStepEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloTaskExecutionStep"
        entity.managedObjectClassName = "HoloTaskExecutionStep"

        var attributes: [NSAttributeDescription] = []
        @discardableResult
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let value { a.defaultValue = value }
            attributes.append(a)
            return a
        }

        let id = attr("id", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        let taskID = attr("taskID", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        // 创建该节点的版本（正文变化=新节点 ID；未变化节点跨版本复用同一 ID）
        let originRevisionID = attr("originRevisionID", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        attr("kindRaw", .stringAttributeType, optional: false, default: HoloTaskExecutionStepKind.action.rawValue)
        // 动作内容与结束点（group 节点复用 actionText 存分组标题，topologyJSON 存成员关系）
        attr("actionText", .stringAttributeType, optional: true)
        attr("doneWhen", .stringAttributeType, optional: true)
        // 引用原清单项时不维护第二份 completed（规格 §3.4）
        attr("sourceCheckItemID", .UUIDAttributeType, optional: true)
        // action 的 pending/waiting/done；取消由版本范围表达，不伪装成 done（规格 §7.2-C）
        let stateRaw = attr("stateRaw", .stringAttributeType, optional: false, default: HoloTaskExecutionStepState.pending.rawValue)
        // 本地并发校验 token（跨设备撤回前验证，规格 §8.3）
        attr("stateVersion", .integer64AttributeType, optional: false, default: 1)
        attr("stateChangedAt", .dateAttributeType, optional: true)
        // 仅 action 的用户明确完成时间；未做不写（规格 §7.2-C）
        attr("completedAt", .dateAttributeType, optional: true)
        // 用户明确提供的等待原因与可选检查时间
        attr("waitReason", .stringAttributeType, optional: true)
        attr("reviewAfter", .dateAttributeType, optional: true)
        // 用户主动留下的简短停留位置/产物说明（可选，规格 §4.6）
        attr("userResumeNote", .stringAttributeType, optional: true)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "taskID": taskID,
            "originRevisionID": originRevisionID,
            "stateRaw": stateRaw,
        ])
        return entity
    }

    // MARK: - HoloTaskExecutionReceipt

    private func makeTaskExecutionReceiptEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloTaskExecutionReceipt"
        entity.managedObjectClassName = "HoloTaskExecutionReceipt"

        var attributes: [NSAttributeDescription] = []
        @discardableResult
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let value { a.defaultValue = value }
            attributes.append(a)
            return a
        }

        let id = attr("id", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        let operationID = attr("operationID", .stringAttributeType, optional: false, default: "")
        let taskID = attr("taskID", .UUIDAttributeType, optional: false, default: TaskExecutionSchemaDefaults.zeroUUID)
        attr("revisionID", .UUIDAttributeType, optional: true)
        attr("stepID", .UUIDAttributeType, optional: true)
        attr("commandRaw", .stringAttributeType, optional: false, default: "")
        attr("actorRaw", .stringAttributeType, optional: false, default: HoloTaskExecutionActor.user.rawValue)
        attr("sourceSurface", .stringAttributeType, optional: false, default: "")
        attr("expectedStateVersion", .integer64AttributeType, optional: true)
        // 命令前后的最小状态快照（解释与安全撤回用；禁止存模型原始对话/附件/隐私证件信息，规格 §7.2-D）
        attr("beforeStateJSON", .stringAttributeType, optional: true)
        attr("afterStateJSON", .stringAttributeType, optional: true)
        // 用户结果断言：只记必要摘要与针对的契约版本
        attr("outcomeAssertion", .stringAttributeType, optional: true)
        attr("revertsReceiptID", .UUIDAttributeType, optional: true)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "taskID": taskID,
            "operationID": operationID,
        ])
        return entity
    }
}
