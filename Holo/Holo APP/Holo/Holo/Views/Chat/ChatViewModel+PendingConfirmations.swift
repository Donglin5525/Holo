//
//  ChatViewModel+PendingConfirmations.swift
//  Holo
//
//  ChatViewModel 机械拆分（体检 R0-51）：仅搬移，不改任何逻辑
//

import Foundation
import Combine
import CoreData
import os.log

extension ChatViewModel {
    // MARK: - Pending Task Confirmation

    /// 待确认任务项谓词（createTask / modifyTaskItems / deleteTask；确认入口含 failed 重试）
    private static func isPendingTaskItem(_ item: AIExecutionItem) -> Bool {
        Self.isTaskActionItem(item)
            && item.status == .skipped
            && item.renderData?["confirmationStatus"] == "pending"
    }

    private static func isTaskActionItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .createTask || item.intent == .modifyTaskItems || item.intent == .deleteTask
    }

    /// 可确认（含失败重试）的任务项
    private static func isConfirmableTaskItem(_ item: AIExecutionItem) -> Bool {
        Self.isTaskActionItem(item)
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 待确认财务项谓词
    private static func isPendingFinanceItem(_ item: AIExecutionItem) -> Bool {
        item.intent.isFinance
            && item.status == .skipped
            && item.renderData?["confirmationStatus"] == "pending"
    }

    /// 把消息里指定 item 的确认状态持久化（基于重读的最新 batch 按 itemId 定位）。
    /// 状态机：pending → confirming（路由执行前落库）→ confirmed / failed / cancelled。
    /// confirming 中间态 + 实体上的 AI 来源标记，构成「确认中途 App 被杀」后的对账依据。
    private func persistConfirmationStatus(messageId: UUID, itemId: String, status: String) {
        guard let msg = messages.first(where: { $0.id == messageId }),
              let batch = msg.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }),
              var rd = batch.items[index].renderData else { return }
        rd["confirmationStatus"] = status
        var updatedItems = batch.items
        let item = updatedItems[index]
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: rd,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: item.errorText
        )
        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: batch.finalText
        )
        chatRepo?.updateMessageMetadata(
            messageId,
            intent: msg.intent,
            extractedDataJSON: Self.encodeExtractedData(msg.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(msg.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 取消息里被点击卡片的待确认财务项：多卡消息按 itemID 精确定位，
    /// 单意图旧格式（itemID 为 nil）退回第一个 pending 项；确认进行中的项不可再操作。
    func pendingFinanceItem(in message: ChatMessageViewData, itemID: String?) -> AIExecutionItem? {
        guard let batch = message.executionBatch else { return nil }
        guard let item = batch.items.first(where: {
            Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
        }) else { return nil }
        guard !confirmingItemIds.contains(item.id) else { return nil }
        return item
    }

    func confirmPendingTask(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isConfirmableTaskItem($0) && (itemID == nil || $0.id == itemID)
              }),
              let renderData = batch.items[pendingIndex].renderData else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认；failed 也放行（失败卡重试走同一入口）
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      ["pending", "failed"].contains(currentItems.renderData?["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                // 路由执行前先落 confirming 中间态（对账依据，与交易侧同构）
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                // 删除确认卡：直接按 ID 删（不回头走关键词模糊匹配路由）
                if currentItems.intent == .deleteTask {
                    var deleteRouteResult: IntentRouter.RouteResult
                    if let taskIdStr = renderData["taskId"],
                       let taskId = UUID(uuidString: taskIdStr),
                       let task = TodoRepository.shared.findTask(by: taskId) {
                        try TodoRepository.shared.deleteTask(task)
                        deleteRouteResult = IntentRouter.RouteResult(
                            text: String(localized: "已删除任务：\(task.title)"),
                            taskId: taskId,
                            linkedEntity: LinkedEntity(type: .task, id: taskId)
                        )
                    } else {
                        deleteRouteResult = IntentRouter.RouteResult(text: String(localized: "任务已不存在，可能已被删除"))
                    }
                    await self.finalizeTaskConfirmation(
                        chatRepo: chatRepo, message: message, itemId: itemId,
                        currentBatch: currentBatch, renderData: renderData,
                        routeResult: deleteRouteResult
                    )
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: renderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)
                await self.finalizeTaskConfirmation(
                    chatRepo: chatRepo, message: message, itemId: itemId,
                    currentBatch: currentBatch, renderData: renderData,
                    routeResult: routeResult
                )
            } catch {
                // 错误回写：标记卡片为 failed
                var failedRenderData = renderData
                failedRenderData["confirmationStatus"] = "failed"
                failedRenderData["errorText"] = error.localizedDescription

                var updatedItems = batch.items
                let pending = updatedItems[pendingIndex]
                updatedItems[pendingIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .failed,
                    summaryText: pending.intent == .modifyTaskItems ? String(localized: "修改条目失败") : String(localized: "创建任务失败"),
                    renderData: failedRenderData,
                    linkedEntityType: nil,
                    linkedEntityId: nil,
                    errorText: error.localizedDescription
                )

                let failedBatch = AIExecutionBatch(
                    mode: batch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: failedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
                )
                self.errorMessage = (pending.intent == .modifyTaskItems ? String(localized: "修改条目失败") : String(localized: "创建任务失败")) + String(localized: "：\(error.localizedDescription)")
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 任务确认成功后的统一回写：来源标记 + confirmed 状态 + 基于最新 batch 定位回写
    private func finalizeTaskConfirmation(
        chatRepo: ChatMessageRepository,
        message: ChatMessageViewData,
        itemId: String,
        currentBatch: AIExecutionBatch,
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult
    ) async {
        // 任务侧来源标记（对账依据，与交易侧同构）
        if let taskId = routeResult.taskId {
            TodoRepository.shared.markTaskAISource(
                taskId: taskId,
                messageId: message.id.uuidString,
                itemId: itemId
            )
        }

        var confirmedRenderData = renderData
        confirmedRenderData["confirmationStatus"] = "confirmed"
        if let entity = routeResult.linkedEntity {
            confirmedRenderData["entityType"] = entity.type.rawValue
            confirmedRenderData["entityId"] = entity.id.uuidString
        }
        if let taskId = routeResult.taskId {
            confirmedRenderData["taskId"] = taskId.uuidString
        }

        // 回写基于重读的最新 batch 按 itemId 定位：
        // 同消息多张卡先后确认时，旧快照里的 pendingIndex 已过期，
        // 会把兄弟卡片刚写入的状态回滚成 pending（诱导重复确认）
        guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else { return }
        var updatedItems = currentBatch.items
        let pending = updatedItems[currentIndex]
        updatedItems[currentIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .success,
            summaryText: routeResult.text,
            renderData: confirmedRenderData,
            linkedEntityType: routeResult.linkedEntity?.type.rawValue,
            linkedEntityId: routeResult.linkedEntity?.id.uuidString,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: currentBatch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 取消任务类待确认卡（创建/修改/删除通用）：置 cancelled，不执行任何动作
    func cancelPendingTask(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingTaskItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: String(localized: "已取消"),
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private static func confirmedFinalText(from items: [AIExecutionItem]) -> String {
        guard !items.isEmpty else { return String(localized: "已处理") }
        if items.count == 1 { return items[0].summaryText }
        // 与真实状态对齐：还有未确认项时不说「已处理」
        let pendingCount = items.filter { $0.status == .skipped }.count
        let body = items.enumerated().map { index, item in
            "\(index + 1). \(item.summaryText)"
        }.joined(separator: "\n")
        if pendingCount == items.count {
            return String(localized: "识别到 \(items.count) 项待办，待你确认后创建：\n") + body
        }
        if pendingCount > 0 {
            return String(localized: "已处理 \(items.count - pendingCount) 项，\(pendingCount) 项待你确认：\n") + body
        }
        return String(localized: "已为你处理 \(items.count) 件事：\n") + body
    }

    // MARK: - Pending Goal Choice Confirmation

    /// 待选择目标项谓词（goalChoice 选择卡）
    private static func isPendingGoalChoiceItem(_ item: AIExecutionItem) -> Bool {
        item.status == .skipped
            && item.renderData?["pendingKind"] == "goalChoice"
            && item.renderData?["confirmationStatus"] == "pending"
    }

    /// 可确认（含失败重试）的目标选择项
    private static func isConfirmableGoalChoiceItem(_ item: AIExecutionItem) -> Bool {
        item.status == .skipped
            && item.renderData?["pendingKind"] == "goalChoice"
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 目标选择卡确认：把选中的 goalId 注入 extractedData 重放路由
    /// （matchGoal 第一级就是 goalId 精确匹配，天然闭环）。
    /// 状态机与任务/交易侧同构：pending → confirming → confirmed / failed。
    func confirmPendingGoalChoice(from message: ChatMessageViewData, itemID: String? = nil, goalId: String) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isConfirmableGoalChoiceItem($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认；failed 也放行（失败卡重试走同一入口）
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      ["pending", "failed"].contains(currentRenderData["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                // 路由执行前先落 confirming 中间态（对账依据，与任务/交易侧同构）
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                var confirmedRenderData = currentRenderData
                confirmedRenderData["goalId"] = goalId

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: confirmedRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)
                GoalNotificationService.broadcastGoalDataChange()

                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let goalUUID = routeResult.linkedEntity?.id,
                   let goal = GoalRepository.shared.findGoal(by: goalUUID) {
                    confirmedRenderData["goalTitle"] = goal.title
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )
            } catch {
                self.writeGoalChoiceError(message: message, itemId: itemId, error: error)
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 取消目标选择卡：置 cancelled，不执行任何动作
    func cancelPendingGoalChoice(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingGoalChoiceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: String(localized: "已取消"),
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 目标选择确认失败回写：标记卡片为 failed，候选行可再次点选重试
    private func writeGoalChoiceError(message: ChatMessageViewData, itemId: String, error: Error) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = batch.items[index]
        guard var renderData = item.renderData else { return }

        renderData["confirmationStatus"] = "failed"
        renderData["errorText"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: renderData,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: error.localizedDescription
        )

        let failedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: failedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
        )
        errorMessage = String(localized: "目标操作失败：\(error.localizedDescription)")
    }

    // MARK: - Pending Transaction Confirmation

    func confirmPendingTransaction(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }

        // 分期入账为 Plus 权益：非 Plus 先弹付费墙，购买成功后自动续上本次确认
        if batch.items[pendingIndex].renderData?["installmentEnabled"] == "true",
           !HoloEntitlementState.shared.isPlusActive {
            HoloPlusActionCoordinator.shared.requirePlus(context: .financeInstallment) { [weak self] in
                self?.confirmPendingTransaction(from: message, itemID: itemID)
            }
            return
        }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            // 重读最新 batch 供校验与回写共用；route 抛错时错误回写也要基于它，
            // 避免旧快照把同消息兄弟卡片的状态回滚
            var latestBatch: AIExecutionBatch?

            do {
                // 重读最新消息状态，防止过期数据重复确认；
                // failed 也放行：失败卡上的「重试」按钮走同一入口
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      currentRenderData["confirmationStatus"] == "pending"
                          || currentRenderData["confirmationStatus"] == "failed" else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                latestBatch = currentBatch

                // 路由执行前先落 confirming 中间态：路由期间 App 被杀，
                // 重启对账据此（配合实体上的 AI 来源标记）判断是否已入账，防止重复确认
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                let intent: AIIntent = currentRenderData["pendingKind"] == "transaction"
                    ? (currentItems.intent == .recordIncome ? .recordIncome : .recordExpense)
                    : currentItems.intent

                let result = ParsedResult(
                    intent: intent,
                    confidence: 1,
                    extractedData: currentRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = currentRenderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let txId = routeResult.transactionId {
                    confirmedRenderData["transactionId"] = txId.uuidString
                }
                if let primary = routeResult.matchedPrimaryCategory {
                    confirmedRenderData["primaryCategory"] = primary
                }
                if let sub = routeResult.matchedSubCategory {
                    confirmedRenderData["subCategory"] = sub
                }

                // 写入 AI 来源标记 + 确认流程来源（对账依据）
                if let txId = routeResult.transactionId {
                    self.markTransactionAsAICreated(
                        txId,
                        candidate: currentRenderData["categoryCandidate"] ?? currentRenderData["note"],
                        sourceMessageId: message.id.uuidString,
                        sourceItemId: itemId
                    )
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )

                // 用户修改过分类时触发学习
                self.recordCategoryLearningIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                self.recordInductionSampleIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )
            } catch {
                self.writeTransactionError(
                    itemId: itemId,
                    batch: latestBatch ?? batch,
                    message: message,
                    error: error
                )
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    func cancelPendingTransaction(from message: ChatMessageViewData, itemID: String? = nil) {
        // 基于重读的最新 batch 取消，且确认进行中的项不允许取消：
        // 否则「确认的路由刚创建实体、取消把卡片改写、确认结果又覆盖回来」会绕过用户最后的意图
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: String(localized: "已取消记账"),
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    // MARK: - Pending Budget / Anniversary Confirmation

    /// 可确认（含失败重试）的预算项
    private static func isConfirmableBudgetItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .setBudget
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 可确认（含失败重试）的纪念日项
    private static func isConfirmableAnniversaryItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .createAnniversary
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    func confirmPendingBudget(from message: ChatMessageViewData, itemID: String? = nil) {
        confirmPendingExecutionCard(from: message, itemID: itemID, matcher: Self.isConfirmableBudgetItem)
    }

    func confirmPendingAnniversary(from message: ChatMessageViewData, itemID: String? = nil) {
        confirmPendingExecutionCard(from: message, itemID: itemID, matcher: Self.isConfirmableAnniversaryItem)
    }

    /// 预算/纪念日确认卡的通用确认流程（与交易确认同构：
    /// 重读最新 batch → confirming 中间态 → route → confirmed 回写）
    private func confirmPendingExecutionCard(
        from message: ChatMessageViewData,
        itemID: String?,
        matcher: (AIExecutionItem) -> Bool
    ) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  matcher($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      ["pending", "failed"].contains(currentRenderData["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: currentRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = currentRenderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                    if entity.type == .anniversary {
                        confirmedRenderData["anniversaryId"] = entity.id.uuidString
                    }
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )
            } catch {
                self.writeExecutionCardError(
                    itemId: itemId,
                    message: message,
                    error: error
                )
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 确认卡 route 抛错的 failed 态回写（供重试），与交易侧 writeTransactionError 同构
    private func writeExecutionCardError(
        itemId: String,
        message: ChatMessageViewData,
        error: Error
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = batch.items[index]
        guard var renderData = item.renderData else { return }

        renderData["confirmationStatus"] = "failed"
        renderData["errorText"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: renderData,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: error.localizedDescription
        )

        let failedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: failedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
        )
        errorMessage = String(localized: "操作失败：\(error.localizedDescription)")
    }

    func cancelPendingBudget(from message: ChatMessageViewData, itemID: String? = nil) {
        cancelPendingExecutionCard(
            from: message,
            itemID: itemID,
            matcher: { $0.intent == .setBudget },
            cancelledText: String(localized: "已取消，预算未改动")
        )
    }

    func cancelPendingAnniversary(from message: ChatMessageViewData, itemID: String? = nil) {
        cancelPendingExecutionCard(
            from: message,
            itemID: itemID,
            matcher: { $0.intent == .createAnniversary },
            cancelledText: String(localized: "已取消，未创建")
        )
    }

    /// 预算/纪念日确认卡的通用取消（基于重读的最新 batch；确认进行中的项不允许取消）
    private func cancelPendingExecutionCard(
        from message: ChatMessageViewData,
        itemID: String?,
        matcher: (AIExecutionItem) -> Bool,
        cancelledText: String
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  matcher($0)
                      && $0.status == .skipped
                      && $0.renderData?["confirmationStatus"] == "pending"
                      && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: cancelledText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// AddTransactionSheet 编辑保存后，将待确认卡片标记为"已确认"（不重复创建交易）
    func dismissPendingCardAfterEdit(
        from message: ChatMessageViewData,
        itemID: String? = nil,
        createdTransaction: Transaction? = nil
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "confirmed"

        // 如果 AddTransactionSheet 创建了交易，补全分类和实体关联信息
        if let tx = createdTransaction, let category = tx.category {
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            renderData["primaryCategory"] = names.primary
            if let sub = names.sub {
                renderData["subCategory"] = sub
            }
            renderData["entityType"] = "finance"
            renderData["entityId"] = tx.id.uuidString
            renderData["transactionId"] = tx.id.uuidString

            // 标记为 AI 创建
            markTransactionAsAICreated(tx.id, candidate: renderData["categoryCandidate"] ?? renderData["note"])

            // 分类学习：将原始候选词映射到用户选择的正确分类
            let candidate = renderData["categoryCandidate"] ?? renderData["note"]
            if let candidateText = candidate, !candidateText.trimmingCharacters(in: .whitespaces).isEmpty {
                let txType: TransactionType = tx.transactionType
                CategoryLearnedMapping.record(
                    candidate: candidateText,
                    type: txType,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                CategoryLearnedMapping.recordInductionSample(
                    candidate: candidateText,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
                CategoryLearnedMapping.tryTriggerInduction(
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
            }
        }

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .success,
            summaryText: String(localized: "已确认并记录"),
            renderData: renderData,
            linkedEntityType: createdTransaction != nil ? "finance" : pending.linkedEntityType,
            linkedEntityId: createdTransaction?.id.uuidString ?? pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func writeTransactionError(
        itemId: String,
        batch: AIExecutionBatch,
        message: ChatMessageViewData,
        error: Error
    ) {
        guard let pendingIndex = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "failed"
        renderData["confirmationError"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .skipped,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: error.localizedDescription
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func latestExecutionBatch(for messageId: UUID) -> AIExecutionBatch? {
        guard let msg = messages.first(where: { $0.id == messageId }) else { return nil }
        return msg.executionBatch
    }

    // MARK: - Pending Transaction Category Update

    func updatePendingTransactionCategory(
        from message: ChatMessageViewData,
        category: Category
    ) {
        guard category.isSubCategory,
              let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]

        // 查找父分类名称
        let parentName = FinanceRepository.shared.parentCategoryName(for: category)
        renderData["primaryCategory"] = parentName
        renderData["subCategory"] = category.name
        renderData["selectedCategoryId"] = category.id.uuidString

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: pending.errorText
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: batch.finalText
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }
}
