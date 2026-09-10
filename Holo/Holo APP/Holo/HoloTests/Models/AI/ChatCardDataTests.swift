//
//  ChatCardDataTests.swift
//  HoloTests
//
//  测试 ChatCardData 枚举和数据模型
//

import XCTest
@testable import Holo

final class ChatCardDataTests: XCTestCase {

    func testLightweightMessageKeepsExecutionRenderDataAndRawLogForFirstFrameCards() throws {
        let executionBatch = AIExecutionBatch(
            mode: .singleAction,
            items: [
                AIExecutionItem(
                    id: "item-1",
                    parseItemId: "parse-1",
                    intent: .recordExpense,
                    status: .success,
                    summaryText: "已记录凉菜 42 元",
                    renderData: [
                        "amount": "42",
                        "note": "凉菜",
                        "primaryCategory": "餐饮",
                        "subCategory": "凉菜",
                        "type": "expense"
                    ],
                    linkedEntityType: "transaction",
                    linkedEntityId: UUID().uuidString,
                    errorText: nil
                )
            ],
            finalText: "已记录"
        )
        let rawLog = LLMLog(calls: [
            LLMCallLog(
                type: "intent_recognition",
                model: "test-model",
                requestMessages: [.user("凉菜 42")],
                responseText: "{}"
            )
        ])

        let message = ChatMessageViewData(lightweightDictionary: [
            "id": UUID(),
            "role": "assistant",
            "content": "已记录",
            "timestamp": Date(),
            "intent": AIIntent.recordExpense.rawValue,
            "extractedDataJSON": #"{"amount":"42","note":"凉菜"}"#,
            "isStreaming": false,
            "executionBatchJSON": String(data: try JSONEncoder().encode(executionBatch), encoding: .utf8)!,
            "rawLogJSON": String(data: try JSONEncoder().encode(rawLog), encoding: .utf8)!
        ])

        XCTAssertEqual(message?.metadataState, .loaded)
        XCTAssertNotNil(message?.rawLog)

        guard let card = ChatCardData.multiple(from: message?.executionBatch).first,
              case .transaction(let transaction) = card else {
            XCTFail("轻量消息首帧应能用 executionBatch 渲染交易卡片")
            return
        }

        XCTAssertEqual(transaction.categoryPath, "餐饮 · 凉菜")
    }

    func testInsightActionCandidatesDeduplicateDuplicateCardIds() {
        InsightFeatureFlags.actionCandidateEnabled = true
        defer { InsightFeatureFlags.resetAll() }

        let cards = [
            MemoryInsightCard(
                id: "duplicate-card",
                type: .finance,
                title: "餐饮消费升高",
                body: "本周餐饮消费高于平时。",
                evidence: [],
                suggestedQuestion: nil,
                moduleHint: "finance",
                patternType: "spending_increase"
            ),
            MemoryInsightCard(
                id: "duplicate-card",
                type: .finance,
                title: "外卖消费升高",
                body: "本周外卖消费高于平时。",
                evidence: [],
                suggestedQuestion: nil,
                moduleHint: "finance",
                patternType: "spending_increase"
            )
        ]

        let result = InsightActionCandidateBuilder.buildCandidateMap(cards: cards, context: nil)

        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result["duplicate-card"])
    }

    // MARK: - ChatCardData.from() 工厂方法

    // MARK: 记账卡片

    func testFromRecordExpense() {
        let data: [String: String] = [
            "amount": "35.5",
            "note": "午饭",
            "primaryCategory": "餐饮",
            "subCategory": "午餐",
            "type": "expense"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.amount, "35.5")
        XCTAssertEqual(cardData.note, "午饭")
        XCTAssertEqual(cardData.primaryCategory, "餐饮")
        XCTAssertEqual(cardData.subCategory, "午餐")
        XCTAssertTrue(cardData.isExpense)
    }

    func testTransactionCardUsesCategoryCandidateAsNameWhenNoteMissing() {
        let data: [String: String] = [
            "amount": "200",
            "categoryCandidate": "给爷爷买彩票",
            "primaryCategory": "人情",
            "subCategory": "人情往来",
            "type": "expense"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.note, "给爷爷买彩票")
        XCTAssertEqual(cardData.displayTitle, "给爷爷买彩票")
    }

    func testTransactionCardUsesTransactionDateAsDisplayDate() {
        let data: [String: String] = [
            "amount": "18",
            "note": "停车",
            "categoryCandidate": "停车费",
            "transactionDate": "2026-07-01",
            "primaryCategory": "交通",
            "type": "expense"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.date, "2026-07-01")
    }

    func testFromRecordIncome() {
        let data: [String: String] = [
            "amount": "10000",
            "primaryCategory": "工资收入",
            "subCategory": "工资"
        ]

        let result = ChatCardData.from(intent: .recordIncome, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.amount, "10000")
        XCTAssertFalse(cardData.isExpense)
    }

    func testIncomeCardShowsMatchedSalaryCategoryPath() {
        let data: [String: String] = [
            "amount": "23870",
            "note": "工资",
            "primaryCategory": "工资收入",
            "subCategory": "工资"
        ]

        let result = ChatCardData.from(intent: .recordIncome, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("工资收入应渲染为交易卡片")
            return
        }

        XCTAssertEqual(cardData.displayTitle, "工资")
        XCTAssertEqual(cardData.categoryPath, "工资收入 · 工资")
    }

    func testUnmatchedFinanceConfirmationDoesNotShowUnableToRecognizeWarning() {
        let expenseText = AIResponseTextBuilder.expenseRecorded(
            amount: "18",
            note: "不知道买了啥",
            accountName: "现金",
            categoryUnmatched: true,
            unmatchedCategory: "不知道买了啥"
        )
        let incomeText = AIResponseTextBuilder.incomeRecorded(
            amount: "88",
            note: "奇怪收入",
            accountName: "现金",
            categoryUnmatched: true,
            unmatchedCategory: "奇怪收入"
        )

        XCTAssertFalse(expenseText.contains("无法识别"))
        XCTAssertFalse(incomeText.contains("无法识别"))
        XCTAssertTrue(expenseText.contains("待分类"))
        XCTAssertTrue(incomeText.contains("待分类"))
    }

    func testFromRecordExpenseMissingAmount() {
        let data: [String: String] = [
            "note": "午饭"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)
        XCTAssertNil(result, "缺少 amount 应返回 nil")
    }

    func testFromRecordExpenseNilData() {
        let result = ChatCardData.from(intent: .recordExpense, data: nil)
        XCTAssertNil(result, "data 为 nil 应返回 nil")
    }

    // MARK: 任务卡片

    func testFromCreateTask() {
        let data: [String: String] = [
            "title": "完成项目报告",
            "dueDate": "今天",
            "priority": "high"
        ]

        let result = ChatCardData.from(intent: .createTask, data: data)

        guard case .task(let cardData) = result else {
            XCTFail("应为 .task 类型")
            return
        }

        XCTAssertEqual(cardData.title, "完成项目报告")
        XCTAssertEqual(cardData.dueDate, "今天")
        XCTAssertEqual(cardData.priority, "high")
    }

    func testFromCreateTaskKeepsDescriptionSubtasksAndPendingState() {
        let data: [String: String] = [
            "title": "购物清单",
            "description": "今天去超市补货",
            "dueDate": "2026-05-30",
            "reminderDate": "2026-05-31 09:00",
            "priority": "medium",
            "subtasks": "买苹果,买胡萝卜,买哈密瓜,买水蜜桃",
            "confirmationStatus": "pending"
        ]

        let result = ChatCardData.from(intent: .createTask, data: data)

        guard case .task(let cardData) = result else {
            XCTFail("应为 .task 类型")
            return
        }

        XCTAssertEqual(cardData.title, "购物清单")
        XCTAssertEqual(cardData.description, "今天去超市补货")
        XCTAssertEqual(cardData.dueDate, "2026-05-30")
        XCTAssertEqual(cardData.reminderDate, "2026-05-31 09:00")
        XCTAssertEqual(cardData.priority, "medium")
        XCTAssertEqual(cardData.subtasks, ["买苹果", "买胡萝卜", "买哈密瓜", "买水蜜桃"])
        XCTAssertTrue(cardData.requiresConfirmation)
    }

    func testFromCreateTaskEmptyTitle() {
        let data: [String: String] = [
            "title": ""
        ]

        let result = ChatCardData.from(intent: .createTask, data: data)
        XCTAssertNil(result, "空标题应返回 nil")
    }

    func testFromCreateTaskMissingTitle() {
        let data: [String: String] = [:]

        let result = ChatCardData.from(intent: .createTask, data: data)
        XCTAssertNil(result, "缺少 title 应返回 nil")
    }

    // MARK: 习惯打卡卡片

    func testFromCheckIn() {
        let data: [String: String] = [
            "habitName": "跑步",
            "streak": "7",
            "completed": "true"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertEqual(cardData.habitName, "跑步")
        XCTAssertEqual(cardData.streak, 7)
        XCTAssertTrue(cardData.completed)
    }

    func testFromCheckInMissingStreak() {
        let data: [String: String] = [
            "habitName": "跑步",
            "completed": "true"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertNil(cardData.streak, "缺少 streak 应为 nil")
    }

    func testFromCheckInDefaultCompleted() {
        let data: [String: String] = [
            "habitName": "冥想"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertTrue(cardData.completed, "默认 completed 应为 true")
    }

    // MARK: 心情卡片

    func testFromRecordMood() {
        let data: [String: String] = [
            "mood": "开心",
            "content": "今天天气不错，心情很好"
        ]

        let result = ChatCardData.from(intent: .recordMood, data: data)

        guard case .mood(let cardData) = result else {
            XCTFail("应为 .mood 类型")
            return
        }

        XCTAssertEqual(cardData.mood, "开心")
        XCTAssertEqual(cardData.content, "今天天气不错，心情很好")
    }

    func testFromRecordMoodEmptyContent() {
        let data: [String: String] = [
            "mood": "开心",
            "content": ""
        ]

        let result = ChatCardData.from(intent: .recordMood, data: data)
        XCTAssertNil(result, "空 content 应返回 nil")
    }

    // MARK: 体重卡片

    func testFromRecordWeight() {
        let data: [String: String] = [
            "weight": "65.5",
            "unit": "kg"
        ]

        let result = ChatCardData.from(intent: .recordWeight, data: data)

        guard case .weight(let cardData) = result else {
            XCTFail("应为 .weight 类型")
            return
        }

        XCTAssertEqual(cardData.weight, "65.5")
        XCTAssertEqual(cardData.unit, "kg")
    }

    func testFromRecordWeightDefaultUnit() {
        let data: [String: String] = [
            "weight": "70"
        ]

        let result = ChatCardData.from(intent: .recordWeight, data: data)

        guard case .weight(let cardData) = result else {
            XCTFail("应为 .weight 类型")
            return
        }

        XCTAssertEqual(cardData.unit, "kg", "默认单位应为 kg")
    }

    // MARK: 不应产生卡片的意图

    func testFromChatReturnsNil() {
        let result = ChatCardData.from(intent: .unknown, data: ["foo": "bar"])
        XCTAssertNil(result, "unknown 不应产生卡片")
    }

    func testFromQueryReturnsNil() {
        let result = ChatCardData.from(intent: .query, data: ["foo": "bar"])
        XCTAssertNil(result, ".query 不应产生卡片")
    }

    func testFromUnknownReturnsNil() {
        let result = ChatCardData.from(intent: .unknown, data: ["foo": "bar"])
        XCTAssertNil(result, ".unknown 不应产生卡片")
    }

    // MARK: - TransactionCardData 计算属性

    private func makeTransactionCardData(
        amount: String = "35",
        note: String?,
        primaryCategory: String?,
        subCategory: String?,
        type: String = "expense",
        date: String? = nil
    ) -> TransactionCardData {
        TransactionCardData(
            amount: amount,
            note: note,
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            type: type,
            date: date,
            confirmationStatus: nil,
            confirmationError: nil,
            installmentEnabled: false,
            installmentTotalAmount: nil,
            installmentPeriods: nil,
            installmentFeePerPeriod: nil,
            installmentSummary: nil,
            installmentPeriodAmounts: []
        )
    }

    func testDisplayTitleWithNote() {
        let data = makeTransactionCardData(
            note: "午饭",
            primaryCategory: "餐饮",
            subCategory: "午餐"
        )
        XCTAssertEqual(data.displayTitle, "午饭")
    }

    func testDisplayTitleWithoutNote() {
        let data = makeTransactionCardData(
            note: nil,
            primaryCategory: "餐饮",
            subCategory: "午餐"
        )
        XCTAssertEqual(data.displayTitle, "午餐", "无 note 时应用子分类名")
    }

    func testDisplayTitleWithoutNoteAndSubCategory() {
        let data = makeTransactionCardData(
            note: nil,
            primaryCategory: "餐饮",
            subCategory: nil
        )
        XCTAssertEqual(data.displayTitle, "餐饮", "无 note 和子分类时应用一级分类名")
    }

    func testDisplayTitleEmptyNote() {
        let data = makeTransactionCardData(
            note: "",
            primaryCategory: "餐饮",
            subCategory: "午餐"
        )
        XCTAssertEqual(data.displayTitle, "午餐", "空 note 时应用子分类名")
    }

    func testCategoryPathWithBoth() {
        let data = makeTransactionCardData(
            note: "午饭",
            primaryCategory: "餐饮",
            subCategory: "午餐"
        )
        XCTAssertEqual(data.categoryPath, "餐饮 · 午餐")
    }

    func testCategoryPathPrimaryOnly() {
        let data = makeTransactionCardData(
            note: "午饭",
            primaryCategory: "餐饮",
            subCategory: nil
        )
        XCTAssertEqual(data.categoryPath, "餐饮")
    }

    func testCategoryPathNilPrimary() {
        let data = makeTransactionCardData(
            note: "午饭",
            primaryCategory: nil,
            subCategory: nil
        )
        XCTAssertNil(data.categoryPath)
    }

    // MARK: - linkedEntityId

    func testLinkedEntityIdTransaction() {
        let data = ["transactionId": "12345678-1234-1234-1234-123456789012"]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "12345678-1234-1234-1234-123456789012")
    }

    func testLinkedEntityIdTask() {
        let data = ["taskId": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testLinkedEntityIdPriority() {
        let data = [
            "transactionId": "11111111-1111-1111-1111-111111111111",
            "taskId": "22222222-2222-2222-2222-222222222222"
        ]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "11111111-1111-1111-1111-111111111111", "应优先返回 transactionId")
    }

    func testLinkedEntityIdNil() {
        XCTAssertNil(ChatCardData.linkedEntityId(from: nil))
        XCTAssertNil(ChatCardData.linkedEntityId(from: [:]))
        XCTAssertNil(ChatCardData.linkedEntityId(from: ["amount": "35"]))
    }

    // MARK: 个人情境规划失败类型化（实施方案 2026-09-09 §5.4：替代旧 try? 静默回落）

    func testContextPlanningFailureMappingCoversTypedCases() {
        // 生成不可用：明确交代「没有完成」且可重试
        let unavailable = ContextPlanningFailure.make(
            from: HoloContextChatPlanner.PlannerError.generationUnavailable
        )
        XCTAssertEqual(unavailable.code, "PLANNING_GENERATION_UNAVAILABLE")
        XCTAssertTrue(unavailable.retryable)
        XCTAssertTrue(unavailable.userMessage.contains("没有完成"))

        // 内层协调器四类语义错误各自有稳定错误码，供日志与后续 UI 细分
        XCTAssertEqual(
            ContextPlanningFailure.make(from: HoloContextPlanningCoordinator.PlanningError.gateClosed).code,
            "PLANNING_GATE_CLOSED"
        )
        XCTAssertEqual(
            ContextPlanningFailure.make(from: HoloContextPlanningCoordinator.PlanningError.staleRun).code,
            "PLANNING_STALE_RUN"
        )
        XCTAssertEqual(
            ContextPlanningFailure.make(from: HoloContextPlanningCoordinator.PlanningError.generationChanged).code,
            "PLANNING_GENERATION_CHANGED"
        )
        XCTAssertEqual(
            ContextPlanningFailure.make(from: HoloContextPlanningCoordinator.PlanningError.undeliverableAfterRepair).code,
            "PLANNING_UNDELIVERABLE"
        )

        // 未知错误走兜底码，文案仍明确交代「不是个性化方案」（不得伪装普通回答）
        struct UnknownPlanningError: Error {}
        let fallback = ContextPlanningFailure.make(from: UnknownPlanningError())
        XCTAssertEqual(fallback.code, "PLANNING_EXECUTION_FAILED")
        XCTAssertTrue(fallback.userMessage.contains("不是个性化方案"))
    }

    // MARK: 规划运行状态机（实施方案 2026-09-09 §5.1/§6.3：revision 单调 + 终态锁 + 对账）

    private func makeRunEnvelope(stage: HoloContextPlanStage) -> HoloContextPlanRunEnvelope {
        let messageID = UUID()
        return HoloContextPlanRunEnvelope(
            runID: messageID.uuidString,
            assistantMessageID: messageID,
            stage: stage
        )
    }

    func testPlanningRunAdvanceIsMonotonicAndTerminalLocked() {
        let controller = HoloContextPlanRunController(envelope: makeRunEnvelope(stage: .planningRecognized))
        XCTAssertTrue(controller.advance(to: .readingPersonalContext))
        XCTAssertEqual(controller.envelope.stage, .readingPersonalContext)
        XCTAssertEqual(controller.envelope.stageRevision, 1)

        XCTAssertTrue(controller.advance(to: .generatingDraft))
        XCTAssertEqual(controller.envelope.stageRevision, 2)

        // 失败终态后，迟到的阶段推进与再次失败都必须被拒绝（§5.1 迟到回调 guard）
        controller.fail(code: "PLANNING_TIMEOUT")
        XCTAssertEqual(controller.envelope.stage, .failed)
        XCTAssertFalse(controller.advance(to: .generatingDraft))
        XCTAssertFalse(controller.fail(code: "PLANNING_TIMEOUT"))
        XCTAssertFalse(controller.advance(to: .draftReady))
        XCTAssertEqual(controller.envelope.stageRevision, 3, "终态后的拒绝不得推进 revision")
    }

    func testPlanningRunCompleteDraftSwapsRealRunID() {
        let controller = HoloContextPlanRunController(envelope: makeRunEnvelope(stage: .generatingDraft))
        let realRunID = "run-abc-123"
        controller.completeDraft(finalRunID: realRunID)
        XCTAssertEqual(controller.envelope.stage, .draftReady)
        XCTAssertEqual(controller.envelope.runID, realRunID)
        XCTAssertTrue(controller.envelope.stage.isTerminal)
    }

    func testPlanningRunCancelWinsOverLateAdvance() {
        let controller = HoloContextPlanRunController(envelope: makeRunEnvelope(stage: .generatingDraft))
        controller.cancel()
        XCTAssertEqual(controller.envelope.stage, .cancelled)
        XCTAssertFalse(controller.advance(to: .draftReady))
        XCTAssertEqual(controller.envelope.stage, .cancelled, "取消终态胜出，迟到结果不得改写")
    }

    func testPlanningRunPersistWritesThroughEachTransition() {
        var written: [Int] = []
        let controller = HoloContextPlanRunController(
            envelope: makeRunEnvelope(stage: .planningRecognized),
            persist: { _, json in
                if let envelope = HoloContextPlanRunController.decode(json) {
                    written.append(envelope.stageRevision)
                }
            }
        )
        controller.advance(to: .readingPersonalContext)
        controller.completeDraft()
        XCTAssertEqual(written, [1, 2], "每次迁移都应原样写穿")
    }

    func testInterruptedRunDetectionSkipsTerminalAndLiveRuns() {
        // 非终态 + 非活跃 → 需要对账；终态/无信封 → 跳过。
        let dead = makeRunEnvelope(stage: .generatingDraft)
        let done = makeRunEnvelope(stage: .draftReady)
        let noRun = UUID()

        let deadID = dead.assistantMessageID
        let doneID = done.assistantMessageID
        let encodedDone = HoloContextPlanRunController.encode(done)

        // controller 存活期间：登记表持有 → 不对账
        var encodedDead: String?
        do {
            let controller = HoloContextPlanRunController(envelope: dead)
            let liveMessage = ChatMessageViewData(
                id: deadID, role: "assistant", content: "",
                timestamp: Date(), intent: nil, extractedDataJSON: nil, isStreaming: true,
                parentMessageId: nil, messageType: .contextPlan,
                contextPlanRunJSON: HoloContextPlanRunController.encode(controller.envelope)
            )
            XCTAssertTrue(HoloContextPlanRunController.interruptedRunIDs(from: [liveMessage]).isEmpty)
            encodedDead = HoloContextPlanRunController.encode(controller.envelope)
        } // 作用域结束 → controller deinit 注销登记表

        let deadMessage = ChatMessageViewData(
            id: deadID, role: "assistant", content: "",
            timestamp: Date(), intent: nil, extractedDataJSON: nil, isStreaming: true,
            parentMessageId: nil, messageType: .contextPlan,
            contextPlanRunJSON: encodedDead
        )
        let doneMessage = ChatMessageViewData(
            id: doneID, role: "assistant", content: "",
            timestamp: Date(), intent: nil, extractedDataJSON: nil, isStreaming: false,
            parentMessageId: nil, messageType: .contextPlan,
            contextPlanRunJSON: encodedDone
        )
        let noRunMessage = ChatMessageViewData(
            id: noRun, role: "assistant", content: "",
            timestamp: Date(), intent: nil, extractedDataJSON: nil, isStreaming: false,
            parentMessageId: nil, messageType: .contextPlan,
            contextPlanRunJSON: nil
        )
        XCTAssertEqual(
            HoloContextPlanRunController.interruptedRunIDs(from: [deadMessage, doneMessage, noRunMessage]),
            [deadID]
        )

        // 对账载荷：revision 递增 + 固定失败码
        let reconciled = HoloContextPlanRunController.interruptedEnvelope(
            for: deadID,
            previous: HoloContextPlanRunController.decode(encodedDead)
        )
        XCTAssertEqual(reconciled.stage, .failed)
        XCTAssertEqual(reconciled.failureCode, "PLANNING_RUN_INTERRUPTED")
    }

    // MARK: 可信表达校验（实施方案 2026-09-09 §9：数据缺失≠零值，推断不带人格标签）

    func testTrustedExpressionViolationScan() {
        // 数据缺失冒充零值：阻断
        XCTAssertNotNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "最近收入为零，建议控制开支。"
        ))
        XCTAssertNotNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "你目前没有任何收入。"
        ))
        // 人格化判断：阻断
        XCTAssertNotNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "你有冲动消费的历史，这次要更保守。"
        ))
        XCTAssertNotNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "考虑到你自控力差，建议设置预算上限。"
        ))
        // 正确口径：不拦
        XCTAssertNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "Holo 最近没有查到收入记录；这不代表你实际没有收入。"
        ))
        XCTAssertNil(HoloContextPlanValidator.firstTrustedExpressionViolation(
            in: "从当前记录看，这个月的餐饮支出比上月高，可能需要留意预算。"
        ))
    }

    func testTrustedExpressionViolationsBlockDelivery() {
        let zero = HoloContextPlanValidator.Finding(code: .dataMissingAsZero, detail: "test")
        let judgment = HoloContextPlanValidator.Finding(code: .personalizedJudgment, detail: "test")
        XCTAssertFalse(HoloContextPlanValidator.isDeliverable(findings: [zero]))
        XCTAssertFalse(HoloContextPlanValidator.isDeliverable(findings: [judgment]))
        // 净化性问题仍是非阻断的
        let sanitized = HoloContextPlanValidator.Finding(code: .unknownContextRef, detail: "test")
        XCTAssertTrue(HoloContextPlanValidator.isDeliverable(findings: [sanitized]))
    }
}
