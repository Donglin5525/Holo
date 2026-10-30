//
//  ReceiptBookingCoordinator.swift
//  Holo
//
//  图片快捷指令自动记账 · 公共协调器（2026-09-14 完整方案 §6.1/§23.4/§28-M1）
//  唯一业务编排入口：压缩 → 摘要 → 幂等预查 → 视觉抽取 → 草案解析 → 门禁 → 原子写入。
//  任何入口（聊天 / 快捷指令 / 分享 / 复核确认）不得各自实现分类和落账。
//
//  M1 范围：book() 全链 + 聊天抽取阶段接入（prepareVisionExtraction）。
//  自动提交受 receiptShortcutAutoCommitEnabled（M2/M3 灰度）约束，M1 默认全部转复核。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ReceiptBookingCoordinator {

    static let shared = ReceiptBookingCoordinator()

    private init() {}

    // MARK: - 聊天抽取阶段（§27.2：聊天调公共 coordinator，保持 alwaysReview 与原卡体验）

    struct VisionPreparation: Sendable {
        let understanding: HoloVisionUnderstanding
        /// 拒识文案（非 nil 时不进记账流）
        let rejectionText: String?
        /// 防重软提示（拍板 9：只提示不阻断）
        let duplicateHints: [String]
        /// 解析好的账户（拍板 6：尾号/关键词命中；nil = 落默认账户）
        let matchedAccountID: UUID?
        let matchedAccountName: String?
        /// 规范化图片摘要来源键（幂等基准；聊天确认写入仍用消息 ID + 卡片项 ID 以兼容启动对账）
        let sourceKey: String
    }

    /// 聊天图片入口的抽取阶段：压缩 + 摘要 + 视觉识别 + 账户解析。
    /// 拒识/防重提示的展示仍由聊天层既有文案渲染；本方法不写任何账。
    func prepareVisionExtraction(
        rawImageData: Data,
        caption: String?
    ) async throws -> VisionPreparation {
        // 产品埋点：识图记账漏斗上游（聊天图片入口；成功侧由 bill_created source=ai 承接）
        HoloProductAnalytics.shared.track(.receiptBookingStarted, ["entry": ReceiptBookingSource.chat.rawValue])
        // 压缩+摘要先行（后台线程）：规范化 JPEG 同时作为上传与幂等基准，
        // 上传复用同一产物（聊天路径原来 extract 内部再压一遍，同图压两次全占主线程）
        let jpeg = await HoloVisionImagePipeline.compressedJPEGInBackground(from: rawImageData)
        let sourceKey = jpeg.map { ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: $0) } ?? ""
        let outcome = try await HoloVisionExtractionService.shared.extract(
            rawImageData: rawImageData,
            caption: caption,
            precompressedJPEG: jpeg
        )

        let resolution = FinanceTransactionDraftResolver.shared.resolveAccount(
            channel: outcome.understanding.paymentChannel,
            choice: .automatic
        )
        let accountID: UUID?
        let accountName: String?
        switch resolution {
        case .resolved(let id, let name, let usedDefault):
            // 落默认账户时不高亮：与既有口径一致（只在识别出更合适账户时展示账户行）
            accountID = usedDefault ? nil : id
            accountName = usedDefault ? nil : name
        case .fixedUnavailable, .noAccountAvailable:
            accountID = nil
            accountName = nil
        }
        return VisionPreparation(
            understanding: outcome.understanding,
            rejectionText: outcome.rejectionText,
            duplicateHints: outcome.duplicateHints,
            matchedAccountID: accountID,
            matchedAccountName: accountName,
            sourceKey: sourceKey
        )
    }

    // MARK: - 统一编排（方案 §23.4）

    /// 完整识别记账链（方案 §23.4）。M1 阶段 autoCommit 决策被灰度开关拦成复核；
    /// 聊天入口固定 alwaysReview（铁律 10）。所有结果写本地结果存储（§22.1 第 5 步）。
    func book(_ request: ReceiptBookingRequest) async -> ReceiptBookingOutcome {
        // 产品埋点：识图记账漏斗上游（快捷指令/分享/锁屏相机入口，entry 取请求来源）
        HoloProductAnalytics.shared.track(.receiptBookingStarted, ["entry": request.source.rawValue])
        // 压缩 + 摘要先行（后台线程：快捷指令跑完 App 被拉到前台的那一刻，
        // 原图解码+多轮 JPEG 编码占主线程会直接顶掉回前台转场动画帧）。
        // 幂等基准 = 实际上传的规范化 JPEG（同一原图同参数压缩结果确定一致）
        let jpeg = await HoloVisionImagePipeline.compressedJPEGInBackground(from: request.rawImageData)
        let sourceKey = jpeg.map { ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: $0) } ?? ""
        let outcome = await runBooking(request, jpeg: jpeg, sourceKey: sourceKey)
        await persist(outcome, request: request, sourceKey: sourceKey, evidenceJPEG: jpeg)
        return outcome
    }

    /// 结果落盘：booked/duplicate/review/rejected/failed 全记 results；
    /// needsReview 另存草案 + 受保护压缩证据（7 天过期，方案 §25.1）
    private func persist(
        _ outcome: ReceiptBookingOutcome,
        request: ReceiptBookingRequest,
        sourceKey: String,
        evidenceJPEG: Data?
    ) async {
        let store = ReceiptBookingResultStore.shared
        switch outcome {
        case .booked(let receipt):
            await store.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .booked, reasonCode: nil,
                summaryText: receipt.summaryText, transactionID: receipt.transactionID,
                draftID: nil, undoToken: receipt.undoToken,
                usedDefaultAccount: receipt.usedDefaultAccount, undoneAt: nil
            ))
        case .duplicate(let receipt):
            await store.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .duplicate, reasonCode: ReceiptBookingReason.reviewPossibleDuplicate.rawValue,
                summaryText: receipt.summaryText, transactionID: receipt.transactionID,
                draftID: nil, undoToken: nil, usedDefaultAccount: false, undoneAt: nil
            ))
        case .needsReview(let snapshot):
            await store.saveReviewDraft(
                snapshot: snapshot,
                choices: (
                    accountRaw: request.accountChoice == .automatic ? "account:auto" : "account:\(accountChoiceID(request.accountChoice))",
                    projectRaw: projectChoiceID(request.projectChoice),
                    modeRaw: request.mode.rawValue
                ),
                sourceKey: sourceKey,
                itemKey: ReceiptBookingIdempotency.itemKey(index: 0),
                evidenceJPEG: evidenceJPEG
            )
            await store.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .needsReview,
                reasonCode: snapshot.reasons.first?.rawValue,
                summaryText: nil, transactionID: nil,
                draftID: snapshot.draftID, undoToken: nil,
                usedDefaultAccount: false, undoneAt: nil
            ))
        case .rejected(let reason):
            await store.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .rejected, reasonCode: reason.rawValue,
                summaryText: nil, transactionID: nil,
                draftID: nil, undoToken: nil, usedDefaultAccount: false, undoneAt: nil
            ))
        case .failed(let failure):
            await store.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .failed, reasonCode: failure.reason.rawValue,
                summaryText: nil, transactionID: nil,
                draftID: nil, undoToken: nil, usedDefaultAccount: false, undoneAt: nil
            ))
        }
    }

    private func accountChoiceID(_ choice: ReceiptAccountChoice) -> String {
        switch choice {
        case .automatic: return "auto"
        case .fixed(let id): return id.uuidString
        }
    }

    private func projectChoiceID(_ choice: ReceiptProjectChoice) -> String {
        switch choice {
        case .noProject: return "project:none"
        case .explicitTextMatch: return "project:explicit"
        case .fixed(let id): return "project:\(id.uuidString)"
        }
    }

    private func runBooking(
        _ request: ReceiptBookingRequest,
        jpeg: Data?,
        sourceKey: String
    ) async -> ReceiptBookingOutcome {
        // 1. 运行资格（授权/账本初始化）
        if let notReady = ReceiptBookingFeaturePolicy.readinessReason() {
            return .failed(ReceiptBookingFailure(
                reason: notReady,
                retryable: false,
                userMessage: String(localized: "请先打开 Holo 完成设置")
            ))
        }

        // 2. 图片不可解码
        let itemKey = ReceiptBookingIdempotency.itemKey(index: 0)
        guard let jpeg else {
            return .rejected(.rejectInvalidImage)
        }

        // 3. 幂等预查（优化：命中直接返回既有交易，省一次视觉调用）
        if let existing = FinanceRepository.shared.findTransactionByAISource(
            messageId: sourceKey, itemId: itemKey
        ), existing.deletedAt == nil {
            return .duplicate(Self.makeReceipt(
                for: existing, sourceKey: sourceKey, itemKey: itemKey, undoToken: nil
            ))
        }

        // 4. 视觉抽取（复用聊天同一条管线与压缩产物，不二次压缩）
        do {
            let outcome = try await HoloVisionExtractionService.shared.extract(
                rawImageData: request.rawImageData,
                caption: request.caption,
                precompressedJPEG: jpeg
            )
            let understanding = outcome.understanding

            // 5. 解析：账户 / 项目 / 分类
            let accountResolution = FinanceTransactionDraftResolver.shared.resolveAccount(
                channel: understanding.paymentChannel,
                choice: request.accountChoice
            )
            let primaryTransaction = understanding.transactions.first
            let projectResolution = FinanceProjectRepository.shared.activeProjects().isEmpty
                ? (resolution: ReceiptProjectResolution.none, dateOutsideRange: false)
                : FinanceTransactionDraftResolver.shared.resolveProject(
                    choice: request.projectChoice,
                    caption: request.caption,
                    imageCandidateTexts: [
                        understanding.merchant,
                        understanding.summary,
                        primaryTransaction?.note,
                    ],
                    transactionDate: Self.resolveTransactionDate(understanding: understanding, capturedAt: request.capturedAt)
                )

            // 6. 门禁（纯函数）
            let policyInput = ReceiptBookingPolicyInput(
                imageType: understanding.imageType,
                currency: understanding.currency,
                paymentStatus: understanding.paymentStatus,
                schemaVersion: understanding.schemaVersion ?? 1,
                guardsPresent: !(outcome.guards ?? []).isEmpty,
                transactions: understanding.transactions.map { tx in
                    ReceiptBookingPolicyTransaction(
                        amount: Self.decimal(from: tx.amount),
                        typeIsIncome: tx.isIncome,
                        confidenceAmount: tx.confidence?.amount,
                        confidenceDirection: tx.confidence?.direction,
                        confidencePaymentStatus: tx.confidence?.paymentStatus
                    )
                },
                fixedAccountUnavailable: {
                    if case .fixedUnavailable = accountResolution { return true }
                    return false
                }(),
                projectChoiceUnavailable: {
                    if case .fixedUnavailable = accountResolution { return true }
                    return false
                }(),
                projectAmbiguous: projectResolution.resolution == .ambiguous,
                transactionDateOutsideProjectRange: projectResolution.dateOutsideRange,
                hasHighCertaintyDuplicate: false,
                hasAmbiguousDuplicate: !outcome.duplicateHints.isEmpty,
                transactionHasExplicitDate: primaryTransaction?.date != nil,
                source: request.source
            )

            let decision = ReceiptBookingPolicy.evaluate(input: policyInput, mode: request.mode)

            switch decision {
            case .reject(let reason):
                return .rejected(reason)

            case .needsReview(let reasons):
                return .needsReview(Self.makeReviewSnapshot(
                    understanding: understanding,
                    reasons: reasons.isEmpty ? [.reviewLegacyContract] : reasons,
                    capturedAt: request.capturedAt,
                    sourceKey: sourceKey
                ))

            case .autoCommit:
                // 自动写三重闸（方案 §30.2）：本地自动开关 + 后端总闸 + 本地确定性门禁
                guard ReceiptBookingAutomationSwitches.autoCommitEnabled,
                      outcome.automationPolicy?.autoCommitAllowed == true else {
                    return .needsReview(Self.makeReviewSnapshot(
                        understanding: understanding,
                        reasons: [],
                        capturedAt: request.capturedAt,
                        sourceKey: sourceKey
                    ))
                }
                return await Self.commitDraft(
                    understanding: understanding,
                    accountResolution: accountResolution,
                    projectResolution: projectResolution,
                    request: request,
                    sourceKey: sourceKey,
                    itemKey: itemKey
                )
            }
        } catch let error as HoloVisionExtractionService.VisionError {
            return .failed(ReceiptBookingFailure(
                reason: .rejectInvalidImage,
                retryable: false,
                userMessage: error.userMessage
            ))
        } catch {
            return .failed(ReceiptBookingFailure(
                reason: ReceiptBookingFailureClassifier.reason(for: error),
                retryable: true,
                userMessage: HoloAIUserErrorMapper.message(for: error)
            ))
        }
    }

    // MARK: - 提交（autoCommit 路径）

    private static func commitDraft(
        understanding: HoloVisionUnderstanding,
        accountResolution: ReceiptAccountResolution,
        projectResolution: (resolution: ReceiptProjectResolution, dateOutsideRange: Bool),
        request: ReceiptBookingRequest,
        sourceKey: String,
        itemKey: String
    ) async -> ReceiptBookingOutcome {
        let repo = FinanceRepository.shared
        let resolver = FinanceTransactionDraftResolver.shared
        let tx = understanding.transactions[0]
        let typeIsIncome = tx.isIncome

        // 分类：完整链路（学习映射→标准→自定义→别名→语义→待分类）
        let note = tx.note ?? understanding.merchant ?? understanding.summary
        let category: Category?
        do {
            category = try await resolver.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: tx.categoryCandidate,
                normalizedCategoryCandidate: tx.normalizedCategoryCandidate,
                semanticCategoryHint: tx.semanticCategoryHint,
                note: note ?? "",
                type: typeIsIncome ? .income : .expense
            )
        } catch {
            category = nil
        }
        let finalCategory: Category
        var categoryIsPending = false
        if let category {
            finalCategory = category
        } else {
            finalCategory = repo.ensurePendingCategory(type: typeIsIncome ? .income : .expense)
            categoryIsPending = true
        }

        // 账户（门禁已把 fixedUnavailable 拦成复核，这里必为 resolved）
        let accountID: UUID
        let accountName: String
        var usedDefaultAccount = false
        switch accountResolution {
        case .resolved(let id, let name, let usedDefault):
            accountID = id
            accountName = name
            usedDefaultAccount = usedDefault
        case .fixedUnavailable, .noAccountAvailable:
            return .failed(ReceiptBookingFailure(
                reason: .failureNotConfigured,
                retryable: false,
                userMessage: String(localized: "请先打开 Holo 创建账户")
            ))
        }

        // 项目（收支同权：收入也可挂项目，如旅行退款；resolved 不再区分收支侧）
        let projectID: UUID?
        let projectName: String?
        switch projectResolution.resolution {
        case .resolved(let id, let name):
            projectID = id
            projectName = name
        case .none, .ambiguous, .fixedUnavailable:
            projectID = nil
            projectName = nil
        }

        let date = Self.resolveTransactionDate(understanding: understanding, capturedAt: request.capturedAt)
        let dateInferred = tx.date == nil

        let names = repo.resolveCategoryNames(from: finalCategory)
        let draft = ResolvedTransactionDraft(
            itemKey: itemKey,
            amount: Self.decimal(from: tx.amount),
            typeIsIncome: typeIsIncome,
            date: date,
            dateInferredFromCapture: dateInferred,
            note: note,
            remark: nil,
            categoryID: finalCategory.id,
            categoryPrimaryName: names.primary,
            categorySubName: names.sub,
            categoryIsPendingFallback: categoryIsPending,
            accountID: accountID,
            accountName: accountName,
            usedDefaultAccount: usedDefaultAccount,
            financeProjectID: projectID,
            financeProjectName: projectName,
            amountOriginalText: tx.amountOriginalText ?? understanding.amountOriginalText,
            paymentStatusOriginalText: understanding.paymentStatusOriginalText,
            paymentChannelOriginalText: understanding.paymentChannel,
            confidenceAmount: tx.confidence?.amount,
            confidenceDirection: tx.confidence?.direction,
            confidencePaymentStatus: tx.confidence?.paymentStatus,
            confidenceDate: tx.confidence?.date,
            imageDigest: sourceKey,
            sourceKey: sourceKey,
            schemaVersion: understanding.schemaVersion ?? 1,
            aiCandidate: tx.categoryCandidate ?? note
        )

        do {
            let result = try FinanceTransactionCommandService.shared.commit(draft: draft, postNotification: true)
            if result.created {
                // 产品埋点：识图自动写入账成功（自动提交灰度常关，M3 开闸后生效；与复核确认页同口径）
                HoloProductAnalytics.shared.track(.billCreated, ["source": "ai"])
                return .booked(Self.makeReceipt(
                    amountText: Self.formatAmount(draft.amount),
                    categoryPath: [names.primary, names.sub].compactMap { $0 }.joined(separator: "/"),
                    accountName: accountName,
                    projectName: projectName,
                    usedDefaultAccount: usedDefaultAccount,
                    categoryNeedsConfirmation: categoryIsPending,
                    dateInferredFromCapture: dateInferred,
                    transactionID: result.transactionID,
                    sourceKey: sourceKey,
                    itemKey: itemKey,
                    undoToken: UUID()
                ))
            }
            // 幂等命中：提交内查重发现既有交易
            return .duplicate(Self.makeReceipt(
                for: repo.findTransaction(by: result.transactionID),
                sourceKey: sourceKey,
                itemKey: itemKey,
                undoToken: nil
            ))
        } catch {
            return .failed(ReceiptBookingFailure(
                reason: .failureServer,
                retryable: true,
                userMessage: String(localized: "记账没有成功，请重试")
            ))
        }
    }


    /// 删除草案 JSON 与证据 JPEG（确认/放弃后），并撤回该草案押后/已投递的待复核提醒
    nonisolated static func discardDraftFiles(draftID: UUID) {
        ReceiptBookingNotificationService.cancelReviewReminders(for: draftID)
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tangyuxuan.holo-app")
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let root = base?.appendingPathComponent("ReceiptBooking", isDirectory: true) else { return }
        try? fm.removeItem(at: root.appendingPathComponent("drafts/\(draftID.uuidString).json"))
        try? fm.removeItem(at: root.appendingPathComponent("evidence/\(draftID.uuidString).jpg"))
    }

    /// 文本金额 → Decimal（复核确认用；容忍「19.90」「¥19.90」「1,234.50」）
    static func decimal(fromText text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Decimal(string: cleaned)
    }

    // MARK: - 工具

    /// 日期规则（方案 §24.2）：票面日期优先；截图/拍小票来源用捕获当天并标记推断
    static func resolveTransactionDate(understanding: HoloVisionUnderstanding, capturedAt: Date) -> Date {
        if let dateString = understanding.transactions.first?.date ?? understanding.paidAt {
            if let parsed = Self.parseISODate(dateString) {
                return parsed
            }
        }
        return capturedAt
    }

    private static func parseISODate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// Double → Decimal 走最短字符串往返，避免二进制浮点尾数污染财务金额
    static func decimal(from value: Double) -> Decimal {
        Decimal(string: value.description) ?? Decimal(value)
    }

    static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    // MARK: - 复核页分类学习写回（与聊天/手动记账同一闭环，2026-10-13）

    /// 确认页用户显式改选科目后写回学习映射。
    /// 口径与 ChatViewModel.recordCategoryLearningIfNeeded 一致：只有用户改过才学，
    /// AI 建议被直接确认不学——防止模型猜测经确认反复自我强化。
    /// candidate 锚点：AI 候选词优先，为空时用商户名（商户在小票上稳定复现，等价于
    /// 聊天侧 candidate ?? note 的文本锚点）；两者皆空无锚点，跳过。
    /// - Returns: 是否记录了学习（守卫/锚点任一不满足返回 false）
    @discardableResult
    static func recordCategoryLearningIfNeeded(
        userSelectedCategoryID: UUID?,
        categoryCandidate: String?,
        merchant: String?,
        typeIsIncome: Bool,
        targetPrimary: String,
        targetSub: String
    ) -> Bool {
        guard userSelectedCategoryID != nil,
              !targetPrimary.isEmpty, !targetSub.isEmpty else { return false }
        let anchor = [categoryCandidate, merchant]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let anchor else { return false }
        let type: TransactionType = typeIsIncome ? .income : .expense
        CategoryLearnedMapping.record(
            candidate: anchor,
            type: type,
            targetPrimary: targetPrimary,
            targetSub: targetSub
        )
        CategoryLearnedMapping.recordInductionSample(
            candidate: anchor,
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
        CategoryLearnedMapping.tryTriggerInduction(
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
        return true
    }

    private static func makeReviewSnapshot(
        understanding: HoloVisionUnderstanding,
        reasons: [ReceiptBookingReason],
        capturedAt: Date,
        sourceKey: String
    ) -> ReceiptReviewSnapshot {
        // 2026-09-19 一图多笔：全部笔逐笔快照，每笔独立幂等键/渠道/日期/分类候选，
        // 字段低置信转成逐笔警示（阈值与自动写门禁同源）
        let items = understanding.transactions.enumerated().map { index, tx -> ReceiptReviewItemSnapshot in
            var notes: [ReceiptBookingReason] = []
            let confidence = tx.confidence
            if (confidence?.amount ?? -1) < ReceiptBookingPolicyThresholds.amount {
                notes.append(.reviewAmountLowConfidence)
            }
            if (confidence?.direction ?? -1) < ReceiptBookingPolicyThresholds.direction {
                notes.append(.reviewDirectionLowConfidence)
            }
            return ReceiptReviewItemSnapshot(
                itemKey: ReceiptBookingIdempotency.itemKey(index: index),
                amountText: formatAmount(decimal(from: tx.amount)),
                typeIsIncome: tx.isIncome,
                dateText: tx.date ?? understanding.paidAt,
                note: tx.note,
                paymentChannel: tx.effectivePaymentChannel(fallback: understanding.paymentChannel),
                amountOriginalText: tx.amountOriginalText,
                categoryCandidate: tx.categoryCandidate,
                normalizedCategoryCandidate: tx.normalizedCategoryCandidate,
                semanticCategoryHint: tx.semanticCategoryHint,
                reviewNotes: notes
            )
        }
        return ReceiptReviewSnapshot(
            draftID: UUID(),
            reasons: reasons,
            items: items,
            merchant: understanding.merchant,
            paymentStatusOriginalText: understanding.paymentStatusOriginalText,
            sourceKey: sourceKey,
            createdAt: capturedAt
        )
    }

    private static func makeReceipt(
        for transaction: Transaction?,
        sourceKey: String,
        itemKey: String,
        undoToken: UUID?
    ) -> ReceiptBookingReceipt {
        let amount = transaction.map { formatAmount($0.amount.decimalValue) } ?? ""
        let note = transaction?.note ?? ""
        return ReceiptBookingReceipt(
            transactionID: transaction?.id ?? UUID(),
            summaryText: "¥\(amount) · \(note)",
            usedDefaultAccount: false,
            categoryNeedsConfirmation: false,
            dateInferredFromCapture: false,
            sourceKey: sourceKey,
            itemKey: itemKey,
            undoToken: undoToken,
            createdAt: Date()
        )
    }

    private static func makeReceipt(
        amountText: String,
        categoryPath: String,
        accountName: String,
        projectName: String?,
        usedDefaultAccount: Bool,
        categoryNeedsConfirmation: Bool,
        dateInferredFromCapture: Bool,
        transactionID: UUID,
        sourceKey: String,
        itemKey: String,
        undoToken: UUID?
    ) -> ReceiptBookingReceipt {
        var summary = String(localized: "已记 ¥\(amountText)")
        if !categoryPath.isEmpty { summary += " · \(categoryPath)" }
        summary += usedDefaultAccount
            ? " · \(accountName)" + String(localized: "（默认）")
            : " · \(accountName)"
        summary += projectName == nil ? String(localized: " · 无项目") : " · \(projectName!)"
        return ReceiptBookingReceipt(
            transactionID: transactionID,
            summaryText: summary,
            usedDefaultAccount: usedDefaultAccount,
            categoryNeedsConfirmation: categoryNeedsConfirmation,
            dateInferredFromCapture: dateInferredFromCapture,
            sourceKey: sourceKey,
            itemKey: itemKey,
            undoToken: undoToken,
            createdAt: Date()
        )
    }
}

// MARK: - 自动提交灰度开关（方案 §30.2；M2 接设置项与远程总闸后的本地侧）

enum ReceiptBookingAutomationSwitches {
    /// M1 固定 false：全部转复核；M3 灰度阶段接 HoloAICapability 本地开关
    static var autoCommitEnabled: Bool { false }
}
