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
import UIKit

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
        let outcome = try await HoloVisionExtractionService.shared.extract(
            rawImageData: rawImageData,
            caption: caption
        )
        let jpeg = HoloVisionImagePipeline.compressedJPEG(from: rawImageData)
        let sourceKey = jpeg.map { ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: $0) } ?? ""

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
        // 压缩 + 摘要先行：幂等基准 = 实际上传的规范化 JPEG（同一原图同参数压缩结果确定一致）
        let jpeg = HoloVisionImagePipeline.compressedJPEG(from: request.rawImageData)
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
            let typeIsIncome = primaryTransaction?.isIncome ?? false
            let projectResolution = FinanceProjectRepository.shared.activeProjects().isEmpty
                ? (resolution: ReceiptProjectResolution.none, dateOutsideRange: false, incomeConflict: false)
                : FinanceTransactionDraftResolver.shared.resolveProject(
                    choice: request.projectChoice,
                    caption: request.caption,
                    imageCandidateTexts: [
                        understanding.merchant,
                        understanding.summary,
                        primaryTransaction?.note,
                    ],
                    transactionDate: Self.resolveTransactionDate(understanding: understanding, capturedAt: request.capturedAt),
                    typeIsIncome: typeIsIncome
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
                    if case .fixedUnavailable = projectResolution.resolution { return true }
                    return false
                }(),
                projectAmbiguous: projectResolution.resolution == .ambiguous,
                incomeWithAttachedProject: {
                    if case .resolved = projectResolution.resolution { return projectResolution.incomeConflict }
                    return false
                }(),
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
                reason: .failureNetwork,
                retryable: true,
                userMessage: HoloAIUserErrorMapper.message(for: error)
            ))
        }
    }

    // MARK: - 提交（autoCommit 路径）

    private static func commitDraft(
        understanding: HoloVisionUnderstanding,
        accountResolution: ReceiptAccountResolution,
        projectResolution: (resolution: ReceiptProjectResolution, dateOutsideRange: Bool, incomeConflict: Bool),
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

        // 项目（收入冲突已被门禁拦成复核，这里 resolved 只出现在支出侧）
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

    /// 复核确认卡的建议科目展示名（完整分类链；不落库）
    func suggestCategoryTitle(for draft: ReceiptBookingResultStore.StoredDraft) async -> String {
        let type: TransactionType = draft.typeIsIncome ? .income : .expense
        let category = try? await FinanceTransactionDraftResolver.shared.matchCategory(
            primaryCategory: nil,
            subCategory: nil,
            categoryCandidate: draft.categoryCandidate,
            normalizedCategoryCandidate: draft.normalizedCategoryCandidate,
            semanticCategoryHint: draft.semanticCategoryHint,
            note: draft.note ?? draft.merchant ?? "",
            type: type
        )
        guard let category else {
            return String(localized: "待分类")
        }
        let names = FinanceRepository.shared.resolveCategoryNames(from: category)
        return [names.primary, names.sub].compactMap { $0 }.joined(separator: "/")
    }

    // MARK: - 复核确认共享入口（§25.2：快捷指令确认卡与 App 内复核页共用，不另写保存代码）

    /// 从已存储草案重建纯值草案并原子落账。
    /// 分类重走完整链；账户按「固定有效→通道解析→默认」；项目按草案配置重放。
    func confirmReviewDraft(draft: ReceiptBookingResultStore.StoredDraft) async -> ReceiptBookingOutcome {
        let repo = FinanceRepository.shared
        let resolver = FinanceTransactionDraftResolver.shared
        let typeIsIncome = draft.typeIsIncome
        let type: TransactionType = typeIsIncome ? .income : .expense

        // 日期
        var date = Date()
        if let dateText = draft.dateText {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: dateText) { date = parsed }
        }

        // 科目（完整分类链，与自动写同一条）
        let note = draft.note ?? draft.merchant
        let category: Category?
        do {
            category = try await resolver.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: draft.categoryCandidate,
                normalizedCategoryCandidate: draft.normalizedCategoryCandidate,
                semanticCategoryHint: draft.semanticCategoryHint,
                note: note ?? "",
                type: type
            )
        } catch {
            category = nil
        }
        let finalCategory = category ?? repo.ensurePendingCategory(type: type)
        let names = repo.resolveCategoryNames(from: finalCategory)

        // 账户：快捷指令固定账户仍有效 → 用它；否则按通道解析（建议账户）→ 默认兜底
        let accountID: UUID
        var usedDefaultAccount = false
        if draft.accountChoiceRaw.hasPrefix("account:"),
           let fixedID = UUID(uuidString: String(draft.accountChoiceRaw.dropFirst("account:".count))),
           let account = repo.findAccount(by: fixedID),
           !account.isArchived, account.deletedAt == nil {
            accountID = fixedID
        } else {
            switch resolver.resolveAccount(channel: draft.paymentChannel, choice: .automatic) {
            case .resolved(let id, _, let isDefault):
                accountID = id
                usedDefaultAccount = isDefault
            case .fixedUnavailable, .noAccountAvailable:
                return .failed(ReceiptBookingFailure(
                    reason: .failureNotConfigured,
                    retryable: false,
                    userMessage: String(localized: "请先打开 Holo 创建账户")
                ))
            }
        }
        let accountName = repo.findAccount(by: accountID)?.name ?? ""

        // 项目：按草案配置重放（收入不挂项目，与门禁口径一致）
        let projectChoice: ReceiptProjectChoice
        switch draft.projectChoiceRaw {
        case "project:explicit":
            projectChoice = .explicitTextMatch
        case let raw where raw.hasPrefix("project:"):
            if let id = UUID(uuidString: String(raw.dropFirst("project:".count))) {
                projectChoice = .fixed(id)
            } else {
                projectChoice = .noProject
            }
        default:
            projectChoice = .noProject
        }
        let projectResolution = FinanceProjectRepository.shared.activeProjects().isEmpty
            ? (resolution: ReceiptProjectResolution.none, dateOutsideRange: false, incomeConflict: false)
            : resolver.resolveProject(
                choice: projectChoice,
                caption: nil,
                imageCandidateTexts: [draft.merchant, note],
                transactionDate: date,
                typeIsIncome: typeIsIncome
            )
        let projectID: UUID?
        let projectName: String?
        if case .resolved(let pid, let pname) = projectResolution.resolution, !typeIsIncome {
            projectID = pid
            projectName = pname
        } else {
            projectID = nil
            projectName = nil
        }

        guard let amount = Self.decimal(fromText: draft.amountText), amount > 0 else {
            return .failed(ReceiptBookingFailure(
                reason: .rejectInvalidImage, retryable: false,
                userMessage: String(localized: "金额无效，请打开 Holo 手动确认这笔。")
            ))
        }

        let draftToCommit = ResolvedTransactionDraft(
            itemKey: draft.itemKey,
            amount: amount,
            typeIsIncome: typeIsIncome,
            date: date,
            dateInferredFromCapture: draft.dateText == nil,
            note: note,
            remark: nil,
            categoryID: finalCategory.id,
            categoryPrimaryName: names.primary,
            categorySubName: names.sub,
            categoryIsPendingFallback: category == nil,
            accountID: accountID,
            accountName: accountName,
            usedDefaultAccount: usedDefaultAccount,
            financeProjectID: projectID,
            financeProjectName: projectName,
            amountOriginalText: draft.amountOriginalText,
            paymentStatusOriginalText: draft.paymentStatusOriginalText,
            paymentChannelOriginalText: draft.paymentChannel,
            confidenceAmount: nil,
            confidenceDirection: nil,
            confidencePaymentStatus: nil,
            confidenceDate: nil,
            imageDigest: draft.sourceKey,
            sourceKey: draft.sourceKey,
            schemaVersion: 2,
            aiCandidate: draft.categoryCandidate
        )

        do {
            let result = try FinanceTransactionCommandService.shared.commit(draft: draftToCommit, postNotification: true)
            // 处理完成：删草案（JSON+证据）
            Self.discardDraftFiles(draftID: draft.id)
            await ReceiptBookingResultStore.shared.append(result: .init(
                id: UUID(), createdAt: Date(),
                kind: result.created ? .booked : .duplicate, reasonCode: nil,
                summaryText: result.created
                    ? String(localized: "复核入账 ¥\(draft.amountText)")
                    : String(localized: "这笔已经记过：¥\(draft.amountText)"),
                transactionID: result.transactionID,
                draftID: nil, undoToken: result.created ? UUID() : nil,
                usedDefaultAccount: usedDefaultAccount, undoneAt: nil
            ))
            if result.created {
                return .booked(Self.makeReceipt(
                    amountText: draft.amountText,
                    categoryPath: [names.primary, names.sub].compactMap { $0 }.joined(separator: "/"),
                    accountName: accountName,
                    projectName: projectName,
                    usedDefaultAccount: usedDefaultAccount,
                    categoryNeedsConfirmation: category == nil,
                    dateInferredFromCapture: false,
                    transactionID: result.transactionID,
                    sourceKey: draft.sourceKey,
                    itemKey: draft.itemKey,
                    undoToken: UUID()
                ))
            }
            return .duplicate(Self.makeReceipt(
                for: repo.findTransaction(by: result.transactionID),
                sourceKey: draft.sourceKey,
                itemKey: draft.itemKey,
                undoToken: nil
            ))
        } catch {
            return .failed(ReceiptBookingFailure(
                reason: .failureServer, retryable: true,
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

    private static func makeReviewSnapshot(
        understanding: HoloVisionUnderstanding,
        reasons: [ReceiptBookingReason],
        capturedAt: Date,
        sourceKey: String
    ) -> ReceiptReviewSnapshot {
        let tx = understanding.transactions.first
        return ReceiptReviewSnapshot(
            draftID: UUID(),
            reasons: reasons,
            amountText: tx.map { formatAmount(decimal(from: $0.amount)) } ?? "",
            typeIsIncome: tx?.isIncome ?? false,
            merchant: understanding.merchant,
            dateText: tx?.date ?? understanding.paidAt,
            note: tx?.note,
            paymentChannel: understanding.paymentChannel,
            amountOriginalText: tx?.amountOriginalText ?? understanding.amountOriginalText,
            paymentStatusOriginalText: understanding.paymentStatusOriginalText,
            categoryCandidate: tx?.categoryCandidate,
            normalizedCategoryCandidate: tx?.normalizedCategoryCandidate,
            semanticCategoryHint: tx?.semanticCategoryHint,
            sourceKey: sourceKey,
            itemKey: ReceiptBookingIdempotency.itemKey(index: 0),
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
