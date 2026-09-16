//
//  ReceiptReviewDetailView.swift
//  Holo
//
//  图片快捷指令自动记账 · 复核详情（2026-09-14 完整方案 §25.2）
//  视觉对齐 Holo 设计系统（2026-09-15 东林反馈：弃用 Form 默认样式、补科目行）。
//  确认落账走同一个 FinanceTransactionCommandService（与自动写/快捷指令确认卡共用），
//  来源键沿用草案 → 幂等不重复入账。
//

import SwiftUI

struct ReceiptReviewDetailView: View {
    let draft: ReceiptBookingResultStore.StoredDraft
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var typeIsIncome = false
    @State private var date = Date()
    @State private var note = ""
    @State private var accounts: [Account] = []
    @State private var projects: [FinanceProject] = []
    @State private var selectedAccountID: UUID?
    @State private var selectedProjectID: UUID?
    /// 科目：nil = 跟随 AI 解析（完整分类链）；选中后以用户选择为准
    @State private var selectedCategoryID: UUID?
    @State private var suggestedCategoryTitle = ""
    @State private var categoriesByType: [Holo.Category] = []
    @State private var evidenceImage: UIImage?
    @State private var evidenceExpanded = false
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                amountCard
                reasonCard
                categoryCard
                accountProjectCard
                dateNoteCard
                if evidenceImage != nil {
                    evidenceCard
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.xl)
        }
        .background(
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()
        )
        .navigationTitle(Text("确认这笔账"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionButtons
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("删除这条草稿", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isCommitting)
            }
        }
        .confirmationDialog("删除这条待复核记录？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteDraft)
        } message: {
            Text("草稿和暂存的证据图会被删除，且不会记账。")
        }
        .onAppear(perform: load)
        .onChange(of: typeIsIncome) { _, isIncome in
            selectedCategoryID = nil
            if isIncome { selectedProjectID = nil }
            refreshCategoryOptions()
        }
    }

    // MARK: - 卡片

    /// 触发原因 + 票面证据
    private var reasonCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.orange)
                    Text(reviewReasonText)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                }
                if let original = draft.amountOriginalText, !original.isEmpty {
                    HStack {
                        Text("票面金额原文").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text(original).font(.footnote).monospacedDigit()
                    }
                }
            }
        }
    }

    private var evidenceCard: some View {
        card {
            DisclosureGroup("查看原图核对", isExpanded: $evidenceExpanded) {
                VStack(spacing: 8) {
                    if let evidenceImage {
                        Image(uiImage: evidenceImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text("仅在本机暂存，确认或删除后自动清理")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 10)
            }
            .font(.subheadline.weight(.medium))
            .tint(.holoPrimary)
        }
    }

    /// 金额与收支方向
    private var amountCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("金额与收支方向").font(.holoLabel).foregroundColor(.holoTextSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("¥").font(.title2.weight(.semibold))
                    TextField("0.00", text: $amountText)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                }
                Picker("方向", selection: $typeIsIncome) {
                    Text("支出").tag(false)
                    Text("收入").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    /// 科目（AI 建议预填，可点改）
    private var categoryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("科目").font(.holoLabel).foregroundColor(.holoTextSecondary)
                Menu {
                    ForEach(topCategories, id: \.id) { top in
                        Menu(top.name) {
                            ForEach(subCategories(of: top), id: \.id) { sub in
                                Button(sub.name) {
                                    selectedCategoryID = sub.id
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "tag")
                            .foregroundStyle(Color.holoPrimary)
                        Text(currentCategoryTitle)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                if selectedCategoryID == nil {
                    Text("已按你的记账习惯自动预填，可点改")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 账户与项目
    private var accountProjectCard: some View {
        card {
            VStack(spacing: 12) {
                HStack {
                    Text("账户").font(.holoBody).foregroundColor(.holoTextPrimary)
                    Spacer()
                    Menu {
                        ForEach(accounts, id: \.id) { account in
                            Button(account.name) {
                                selectedAccountID = account.id
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentAccountName).foregroundColor(.holoTextPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
                Divider()
                if typeIsIncome {
                    HStack {
                        Text("项目").font(.holoBody).foregroundColor(.holoTextPrimary)
                        Spacer()
                        Text("收入不挂项目")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("项目").font(.holoBody).foregroundColor(.holoTextPrimary)
                        Spacer()
                        Menu {
                            Button("不挂项目") { selectedProjectID = nil }
                            ForEach(projects, id: \.id) { project in
                                Button(project.name) { selectedProjectID = project.id }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentProjectName).foregroundColor(.holoTextPrimary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 日期与备注
    private var dateNoteCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                    .font(.holoBody)
                TextField("备注", text: $note)
                    .font(.holoBody)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                confirm()
            } label: {
                HStack(spacing: 8) {
                    if isCommitting {
                        ProgressView().tint(.white)
                    }
                    Text("确认记账")
                        .font(.holoBody.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(canCommit ? Color.holoPrimary : Color.holoPrimary.opacity(0.4))
                )
                .foregroundStyle(Color.white)
            }
            .disabled(!canCommit || isCommitting)

            Button {
                dismiss()
            } label: {
                Text("稍后处理")
                    .font(.holoBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.holoCardBackground)
                    )
            }
            .disabled(isCommitting)
        }
        .padding(.top, HoloSpacing.xs)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(HoloSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.holoCardBackground)
            )
    }

    // MARK: - 派生状态

    private var amountIsValid: Bool {
        (ReceiptBookingCoordinator.decimal(fromText: amountText) ?? 0) > 0
    }

    private var canCommit: Bool {
        amountIsValid && selectedAccountID != nil
    }

    private var topCategories: [Holo.Category] {
        categoriesByType.filter { $0.isTopLevel }
    }

    private func subCategories(of top: Holo.Category) -> [Holo.Category] {
        categoriesByType.filter { !$0.isTopLevel && $0.parentId == top.id }
    }

    /// 当前生效科目名：用户改选 > AI 解析建议
    private var currentCategoryTitle: String {
        if let selectedCategoryID,
           let selected = categoriesByType.first(where: { $0.id == selectedCategoryID }) {
            return selected.name
        }
        return suggestedCategoryTitle.isEmpty ? String(localized: "正在匹配科目…") : suggestedCategoryTitle
    }

    private var currentAccountName: String {
        if let selectedAccountID,
           let account = accounts.first(where: { $0.id == selectedAccountID }) {
            return account.name
        }
        return String(localized: "自动识别")
    }

    private var currentProjectName: String {
        if let selectedProjectID,
           let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project.name
        }
        return String(localized: "不挂项目")
    }

    private var reviewReasonText: String {
        guard let first = draft.reasons.first, let reason = ReceiptBookingReason(rawValue: first) else {
            return String(localized: "这笔账需要你确认。")
        }
        switch reason {
        case .reviewMultipleTransactions: return String(localized: "图里有多笔交易，先确认这一笔，其余请在账本手动记。")
        case .reviewAmountLowConfidence, .reviewAmountConflict: return String(localized: "金额没认准，请核对。")
        case .reviewDirectionLowConfidence: return String(localized: "收支方向不确定，请选择。")
        case .reviewPaymentStatusLowConfidence: return String(localized: "支付状态不确定。")
        case .reviewDateMissingForHistoricalImage: return String(localized: "图片里没有日期，请选择记账日期。")
        case .reviewPossibleDuplicate: return String(localized: "可能已经记过一笔，请核对后再确认。")
        case .reviewAccountChoiceUnavailable: return String(localized: "快捷指令里固定的账户已失效，请重新选择账户，并更新那条快捷指令。")
        case .reviewProjectChoiceUnavailable: return String(localized: "快捷指令里固定的项目已结束，请重新选择，并更新那条快捷指令。")
        case .reviewProjectAmbiguous: return String(localized: "匹配到多个项目，请手动选择。")
        case .reviewDateOutsideProjectRange: return String(localized: "日期不在项目周期内，确认后仍会挂到该项目。")
        case .reviewContractGuarded: return String(localized: "识别结果有异常，请人工核对。")
        // 人话文案（2026-09-15 东林反馈）：旧契约灰度提示不该说「服务需要更新」
        case .reviewLegacyContract: return String(localized: "识别信息不完整，请核对后保存。")
        default: return String(localized: "这笔账需要你确认。")
        }
    }

    // MARK: - 数据

    private func load() {
        amountText = draft.amountText
        typeIsIncome = draft.typeIsIncome
        note = draft.note ?? ""
        if let dateText = draft.dateText {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: dateText) {
                date = parsed
            }
        }
        let repo = FinanceRepository.shared
        accounts = repo.getAccounts(includeArchived: false)
        projects = FinanceProjectRepository.shared.activeProjects()

        // 账户建议（§25.2）：固定账户仍有效则预填；否则按识别通道解析；再落默认
        if selectedAccountID == nil {
            var suggested: UUID?
            if draft.accountChoiceRaw.hasPrefix("account:"),
               let fixedID = UUID(uuidString: String(draft.accountChoiceRaw.dropFirst("account:".count))),
               let account = repo.findAccount(by: fixedID),
               !account.isArchived, account.deletedAt == nil {
                suggested = fixedID
            }
            if suggested == nil {
                switch FinanceTransactionDraftResolver.shared.resolveAccount(
                    channel: draft.paymentChannel, choice: .automatic
                ) {
                case .resolved(let id, _, _):
                    suggested = id
                case .fixedUnavailable, .noAccountAvailable:
                    break
                }
            }
            selectedAccountID = suggested ?? repo.getDefaultAccountSync()?.id ?? accounts.first?.id
        }
        if selectedProjectID == nil, draft.projectChoiceRaw.hasPrefix("project:") {
            selectedProjectID = UUID(uuidString: String(draft.projectChoiceRaw.dropFirst("project:".count)))
        }

        refreshCategoryOptions()
        // 本机暂存的复核证据图（确认/删除后随之删除）
        if let url = ReceiptBookingResultStore.evidenceImageURL(for: draft.id),
           let data = try? Data(contentsOf: url) {
            evidenceImage = UIImage(data: data)
        }
    }

    private func refreshCategoryOptions() {
        let type: TransactionType = typeIsIncome ? .income : .expense
        suggestedCategoryTitle = ""
        Task { @MainActor in
            let repo = FinanceRepository.shared
            categoriesByType = (try? await repo.getCategories(by: type)) ?? []
            let category = try? await FinanceTransactionDraftResolver.shared.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: draft.categoryCandidate,
                normalizedCategoryCandidate: draft.normalizedCategoryCandidate,
                semanticCategoryHint: draft.semanticCategoryHint,
                note: note.isEmpty ? (draft.merchant ?? draft.note ?? "") : note,
                type: type
            )
            suggestedCategoryTitle = category?.name ?? String(localized: "待分类")
        }
    }

    // MARK: - 确认（走公共 CommandService，§25.2）

    private func confirm() {
        guard let amount = ReceiptBookingCoordinator.decimal(fromText: amountText), amount > 0 else { return }
        guard let accountID = selectedAccountID else { return }
        isCommitting = true
        errorMessage = nil

        Task { @MainActor in
            defer { isCommitting = false }
            let repo = FinanceRepository.shared
            let resolver = FinanceTransactionDraftResolver.shared

            // 科目：用户改选 > 完整分类链重解析 > 待分类
            let category: Holo.Category?
            if let selectedCategoryID {
                category = repo.findCategory(by: selectedCategoryID)
            } else {
                do {
                    category = try await resolver.matchCategory(
                        primaryCategory: nil,
                        subCategory: nil,
                        categoryCandidate: draft.categoryCandidate,
                        normalizedCategoryCandidate: draft.normalizedCategoryCandidate,
                        semanticCategoryHint: draft.semanticCategoryHint,
                        note: note.isEmpty ? (draft.merchant ?? draft.note ?? "") : note,
                        type: typeIsIncome ? .income : .expense
                    )
                } catch {
                    category = nil
                }
            }
            let finalCategory: Holo.Category = category ?? repo.ensurePendingCategory(type: typeIsIncome ? .income : .expense)
            let names = repo.resolveCategoryNames(from: finalCategory)
            let accountName = repo.findAccount(by: accountID)?.name ?? ""

            let draftToCommit = ResolvedTransactionDraft(
                itemKey: draft.itemKey,
                amount: amount,
                typeIsIncome: typeIsIncome,
                date: date,
                dateInferredFromCapture: draft.dateText == nil,
                note: note.isEmpty ? draft.note : note,
                remark: nil,
                categoryID: finalCategory.id,
                categoryPrimaryName: names.primary,
                categorySubName: names.sub,
                categoryIsPendingFallback: category == nil,
                accountID: accountID,
                accountName: accountName,
                usedDefaultAccount: repo.getDefaultAccountSync()?.id == accountID,
                financeProjectID: selectedProjectID,
                financeProjectName: projects.first(where: { $0.id == selectedProjectID })?.name,
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
                await ReceiptBookingResultStore.shared.append(result: .init(
                    id: UUID(), createdAt: Date(),
                    kind: result.created ? .booked : .duplicate, reasonCode: nil,
                    summaryText: result.created
                        ? String(localized: "复核入账 ¥\(amountText)")
                        : String(localized: "这笔已经记过：¥\(amountText)"),
                    transactionID: result.transactionID,
                    draftID: nil, undoToken: result.created ? UUID() : nil,
                    usedDefaultAccount: repo.getDefaultAccountSync()?.id == accountID, undoneAt: nil
                ))
                ReceiptBookingCoordinator.discardDraftFiles(draftID: draft.id)
                onFinished()
                dismiss()
                // 弹层收起动画后再广播一次：账本/账户页监听 .financeDataDidChange 即时重算汇总
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                }
            } catch {
                errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func deleteDraft() {
        ReceiptBookingCoordinator.discardDraftFiles(draftID: draft.id)
        Task {
            await ReceiptBookingResultStore.shared.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .rejected, reasonCode: nil,
                summaryText: String(localized: "已删除一条待复核记录"), transactionID: nil,
                draftID: nil, undoToken: nil, usedDefaultAccount: false, undoneAt: nil
            ))
        }
        onFinished()
        dismiss()
    }
}
