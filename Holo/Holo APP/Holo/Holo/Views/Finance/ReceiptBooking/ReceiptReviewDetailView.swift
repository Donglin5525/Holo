//
//  ReceiptReviewDetailView.swift
//  Holo
//
//  图片快捷指令自动记账 · 复核详情（2026-09-14 完整方案 §25.2）
//  视觉对齐 Holo 设计系统（2026-09-15 东林反馈：弃用 Form 默认样式、补科目行）。
//  确认落账走同一个 FinanceTransactionCommandService（与自动写/快捷指令确认卡共用），
//  来源键沿用草案 → 幂等不重复入账。
//  2026-09-19 一图多笔：一张确认卡承载全部笔，逐笔编辑/可剔除、逐笔账户按
//  各自支付渠道预填、一次确认整批落账（部分重复命中不算失败）。
//

import SwiftUI

struct ReceiptReviewDetailView: View {
    let draft: ReceiptBookingResultStore.StoredDraft
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 逐笔编辑状态（一图多笔；旧单笔草稿 effectiveItems 合成一条）
    private struct ItemEditState: Identifiable {
        let id: String   // itemKey
        let title: String
        let item: ReceiptBookingResultStore.StoredDraftItem
        var included = true
        var amountText: String
        var typeIsIncome: Bool
        var date = Date()
        var note = ""
        var selectedAccountID: UUID?
        var selectedProjectID: UUID?
        /// 科目：nil = 跟随 AI 解析（完整分类链）；选中后以用户选择为准
        var selectedCategoryID: UUID?
        var suggestedCategoryTitle = ""
        var suggestedCategoryTask: Task<Void, Never>?
    }

    @State private var itemStates: [ItemEditState] = []
    @State private var accounts: [Account] = []
    @State private var projects: [FinanceProject] = []
    @State private var expenseCategories: [Holo.Category] = []
    @State private var incomeCategories: [Holo.Category] = []
    @State private var evidenceImage: UIImage?
    @State private var evidenceExpanded = false
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                summaryCard
                reasonCard
                ForEach($itemStates) { $state in
                    itemCard(for: $state)
                }
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
        .navigationTitle(itemStates.count > 1 ? Text("确认这几笔账") : Text("确认这笔账"))
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
        .onDisappear {
            for index in itemStates.indices {
                itemStates[index].suggestedCategoryTask?.cancel()
            }
        }
    }

    // MARK: - 卡片

    /// 汇总：多笔显示笔数与同向合计；识别时间必显（2026-09-23 起旧草案一眼可辨）
    private var summaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(itemCountText)
                        .font(.holoBody.weight(.semibold))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    if let total = uniformTotalText {
                        Text("¥\(total)")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                Text("识别于 \(ReceiptRecognizedTimeText.text(for: draft.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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

    /// 单笔编辑卡：可剔除 + 金额/方向/科目/账户/项目/日期/备注
    private func itemCard(for state: Binding<ItemEditState>) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.wrappedValue.title)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    Toggle("不记这笔", isOn: state.included)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.holoPrimary)
                        .disabled(isCommitting)
                }

                if state.wrappedValue.included {
                if let notes = state.wrappedValue.item.reviewNotes, !notes.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                        Text(itemReviewNotesText(notes))
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("¥").font(.title2.weight(.semibold))
                        TextField("0.00", text: state.amountText)
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                    }
                    Picker("方向", selection: state.typeIsIncome) {
                        Text("支出").tag(false)
                        Text("收入").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.wrappedValue.typeIsIncome) { _, _ in
                        state.wrappedValue.selectedCategoryID = nil
                        if state.wrappedValue.typeIsIncome { state.wrappedValue.selectedProjectID = nil }
                        refreshCategorySuggestion(index: itemIndex(of: state.wrappedValue.id))
                    }
                    if let original = state.wrappedValue.item.amountOriginalText, !original.isEmpty {
                        HStack {
                            Text("票面金额原文").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Text(original).font(.footnote).monospacedDigit()
                        }
                    }

                    Divider()

                    categoryRow(for: state)

                    Divider()

                    accountRow(for: state)

                    Divider()

                    projectRow(for: state)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("日期", selection: state.date, displayedComponents: .date)
                            .font(.holoBody)
                        TextField("备注", text: state.note)
                            .font(.holoBody)
                    }
                }
            }
        }
    }

    /// 科目行（AI 建议预填，可点改）
    private func categoryRow(for state: Binding<ItemEditState>) -> some View {
        let categories = state.wrappedValue.typeIsIncome ? incomeCategories : expenseCategories
        return HStack {
            Text("科目").font(.holoBody).foregroundColor(.holoTextPrimary)
            Spacer()
            Menu {
                ForEach(topLevelCategories(in: categories), id: \.id) { top in
                    Menu(top.name) {
                        ForEach(subCategories(of: top, in: categories), id: \.id) { sub in
                            Button(sub.name) {
                                state.wrappedValue.selectedCategoryID = sub.id
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentCategoryTitle(for: state.wrappedValue, categories: categories))
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }

    /// 账户行：预填=逐笔渠道解析（各笔渠道可能不同），可点改
    private func accountRow(for state: Binding<ItemEditState>) -> some View {
        HStack {
            Text("账户").font(.holoBody).foregroundColor(.holoTextPrimary)
            Spacer()
            Menu {
                ForEach(accounts, id: \.id) { account in
                    Button(account.name) {
                        state.wrappedValue.selectedAccountID = account.id
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentAccountName(for: state.wrappedValue))
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }

    /// 项目行：支出可挂，收入不挂
    private func projectRow(for state: Binding<ItemEditState>) -> some View {
        Group {
            if state.wrappedValue.typeIsIncome {
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
                        Button("不挂项目") { state.wrappedValue.selectedProjectID = nil }
                        ForEach(projects, id: \.id) { project in
                            Button(project.name) { state.wrappedValue.selectedProjectID = project.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentProjectName(for: state.wrappedValue))
                                .foregroundColor(.holoTextPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
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
                    Text(commitButtonTitle)
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

    private var includedStates: [ItemEditState] {
        itemStates.filter(\.included)
    }

    private var itemCountText: String {
        includedStates.count == 1
            ? String(localized: "1 笔待确认")
            : String(localized: "\(includedStates.count) 笔待确认")
    }

    private var uniformTotalText: String? {
        let included = includedStates
        guard let first = included.first, !included.isEmpty else { return nil }
        guard included.allSatisfy({ $0.typeIsIncome == first.typeIsIncome }) else { return nil }
        let total = included.reduce(Decimal(0)) {
            $0 + (ReceiptBookingCoordinator.decimal(fromText: $1.amountText) ?? 0)
        }
        return ReceiptBookingCoordinator.formatAmount(total)
    }

    private var commitButtonTitle: String {
        let count = includedStates.count
        return count == 1 ? String(localized: "确认记账") : String(localized: "确认记 \(count) 笔")
    }

    private var canCommit: Bool {
        let included = includedStates
        guard !included.isEmpty else { return false }
        return included.allSatisfy { state in
            (ReceiptBookingCoordinator.decimal(fromText: state.amountText) ?? 0) > 0
                && state.selectedAccountID != nil
        }
    }

    private func topLevelCategories(in categories: [Holo.Category]) -> [Holo.Category] {
        categories.filter { $0.isTopLevel }
    }

    private func subCategories(of top: Holo.Category, in categories: [Holo.Category]) -> [Holo.Category] {
        categories.filter { !$0.isTopLevel && $0.parentId == top.id }
    }

    /// 当前生效科目名：用户改选 > AI 解析建议
    private func currentCategoryTitle(for state: ItemEditState, categories: [Holo.Category]) -> String {
        if let selectedCategoryID = state.selectedCategoryID,
           let selected = categories.first(where: { $0.id == selectedCategoryID }) {
            return selected.name
        }
        return state.suggestedCategoryTitle.isEmpty ? String(localized: "正在匹配科目…") : state.suggestedCategoryTitle
    }

    private func currentAccountName(for state: ItemEditState) -> String {
        if let selectedAccountID = state.selectedAccountID,
           let account = accounts.first(where: { $0.id == selectedAccountID }) {
            return account.name
        }
        return String(localized: "自动识别")
    }

    private func currentProjectName(for state: ItemEditState) -> String {
        if let selectedProjectID = state.selectedProjectID,
           let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project.name
        }
        return String(localized: "不挂项目")
    }

    private func itemIndex(of itemKey: String) -> Int? {
        itemStates.firstIndex { $0.id == itemKey }
    }

    private var reviewReasonText: String {
        guard let first = draft.reasons.first, let reason = ReceiptBookingReason(rawValue: first) else {
            return String(localized: "这笔账需要你确认。")
        }
        switch reason {
        case .reviewMultipleTransactions:
            return String(localized: "图里有多笔交易，都留在这张确认卡里了，勾掉不想记的、核对金额后一次入账。")
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

    private func itemReviewNotesText(_ notes: [String]) -> String {
        let parts = notes.compactMap { ReceiptBookingReason(rawValue: $0) }.map { reason -> String in
            switch reason {
            case .reviewAmountLowConfidence, .reviewAmountConflict:
                return String(localized: "金额没认准")
            case .reviewDirectionLowConfidence:
                return String(localized: "方向不确定")
            default:
                return String(localized: "请核对")
            }
        }
        return parts.joined(separator: "、")
    }

    // MARK: - 数据

    private func load() {
        let repo = FinanceRepository.shared
        accounts = repo.getAccounts(includeArchived: false)
        projects = FinanceProjectRepository.shared.activeProjects()

        itemStates = draft.effectiveItems.enumerated().map { itemIndex, item in
            var state = ItemEditState(
                id: item.itemKey,
                title: String(localized: "第 \(itemIndex + 1) 笔"),
                item: item,
                amountText: item.amountText,
                typeIsIncome: item.typeIsIncome
            )
            if let dateText = item.dateText {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                if let parsed = formatter.date(from: dateText) {
                    state.date = parsed
                }
            }
            state.note = item.note ?? ""
            // 账户建议（§25.2）：固定账户仍有效则整单预填；否则按该笔自己的渠道解析；再落默认
            if state.selectedAccountID == nil {
                var suggested: UUID?
                if draft.accountChoiceRaw.hasPrefix("account:"),
                   let fixedID = UUID(uuidString: String(draft.accountChoiceRaw.dropFirst("account:".count))),
                   let account = repo.findAccount(by: fixedID),
                   !account.isArchived, account.deletedAt == nil {
                    suggested = fixedID
                }
                if suggested == nil {
                    switch FinanceTransactionDraftResolver.shared.resolveAccount(
                        channel: item.paymentChannel, choice: .automatic
                    ) {
                    case .resolved(let id, _, _):
                        suggested = id
                    case .fixedUnavailable, .noAccountAvailable:
                        break
                    }
                }
                state.selectedAccountID = suggested ?? repo.getDefaultAccountSync()?.id ?? accounts.first?.id
            }
            // 固定项目传给支出笔预填；收入笔不挂
            if !item.typeIsIncome, state.selectedProjectID == nil,
               draft.projectChoiceRaw.hasPrefix("project:"),
               let projectID = UUID(uuidString: String(draft.projectChoiceRaw.dropFirst("project:".count))),
               projects.contains(where: { $0.id == projectID }) {
                state.selectedProjectID = projectID
            }
            return state
        }

        // 科目选项两套（支出/收入）异步拉取；建议标题由 refreshCategorySuggestion 独立跑
        Task { @MainActor in
            expenseCategories = (try? await repo.getCategories(by: .expense)) ?? []
            incomeCategories = (try? await repo.getCategories(by: .income)) ?? []
        }
        for index in itemStates.indices {
            refreshCategorySuggestion(index: index)
        }
        // 本机暂存的复核证据图（确认/删除后随之删除）
        if let url = ReceiptBookingResultStore.evidenceImageURL(for: draft.id),
           let data = try? Data(contentsOf: url) {
            evidenceImage = UIImage(data: data)
        }
    }

    /// 科目建议：逐笔走完整分类链（学习映射→标准→自定义→别名→语义）
    private func refreshCategorySuggestion(index: Int?) {
        guard let index else { return }
        let state = itemStates[index]
        state.suggestedCategoryTask?.cancel()
        let type: TransactionType = state.typeIsIncome ? .income : .expense
        let task = Task { @MainActor in
            let repo = FinanceRepository.shared
            let category = try? await FinanceTransactionDraftResolver.shared.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: state.item.categoryCandidate,
                normalizedCategoryCandidate: state.item.normalizedCategoryCandidate,
                semanticCategoryHint: state.item.semanticCategoryHint,
                note: state.note.isEmpty ? (state.item.note ?? draft.merchant ?? "") : state.note,
                type: type
            )
            guard !Task.isCancelled, let index = itemIndex(of: state.id) else { return }
            itemStates[index].suggestedCategoryTitle = category?.name ?? String(localized: "待分类")
        }
        itemStates[index].suggestedCategoryTask = task
        itemStates[index].suggestedCategoryTitle = ""
    }

    // MARK: - 确认（走公共 CommandService，§25.2；逐笔提交整批完成）

    private func confirm() {
        let included = includedStates
        guard !included.isEmpty else { return }
        isCommitting = true
        errorMessage = nil

        Task { @MainActor in
            defer { isCommitting = false }
            let repo = FinanceRepository.shared
            let resolver = FinanceTransactionDraftResolver.shared
            var committedIDs: [UUID] = []
            var duplicateCount = 0
            var failureCount = 0

            for item in included {
                guard let amount = ReceiptBookingCoordinator.decimal(fromText: item.amountText), amount > 0,
                      let accountID = item.selectedAccountID else {
                    failureCount += 1
                    continue
                }

                // 科目：用户改选 > 完整分类链重解析 > 待分类
                let categories = item.typeIsIncome ? incomeCategories : expenseCategories
                let category: Holo.Category?
                if let selectedCategoryID = item.selectedCategoryID {
                    category = repo.findCategory(by: selectedCategoryID)
                } else {
                    do {
                        category = try await resolver.matchCategory(
                            primaryCategory: nil,
                            subCategory: nil,
                            categoryCandidate: item.item.categoryCandidate,
                            normalizedCategoryCandidate: item.item.normalizedCategoryCandidate,
                            semanticCategoryHint: item.item.semanticCategoryHint,
                            note: item.note.isEmpty ? (item.item.note ?? draft.merchant ?? "") : item.note,
                            type: item.typeIsIncome ? .income : .expense
                        )
                    } catch {
                        category = nil
                    }
                }
                let finalCategory: Holo.Category = category ?? repo.ensurePendingCategory(type: item.typeIsIncome ? .income : .expense)
                let names = repo.resolveCategoryNames(from: finalCategory)
                let accountName = repo.findAccount(by: accountID)?.name ?? ""

                let draftToCommit = ResolvedTransactionDraft(
                    itemKey: item.id,
                    amount: amount,
                    typeIsIncome: item.typeIsIncome,
                    date: item.date,
                    dateInferredFromCapture: item.item.dateText == nil,
                    note: item.note.isEmpty ? item.item.note : item.note,
                    remark: nil,
                    categoryID: finalCategory.id,
                    categoryPrimaryName: names.primary,
                    categorySubName: names.sub,
                    categoryIsPendingFallback: category == nil,
                    accountID: accountID,
                    accountName: accountName,
                    usedDefaultAccount: repo.getDefaultAccountSync()?.id == accountID,
                    financeProjectID: item.selectedProjectID,
                    financeProjectName: projects.first(where: { $0.id == item.selectedProjectID })?.name,
                    amountOriginalText: item.item.amountOriginalText,
                    paymentStatusOriginalText: draft.paymentStatusOriginalText,
                    paymentChannelOriginalText: item.item.paymentChannel,
                    confidenceAmount: nil,
                    confidenceDirection: nil,
                    confidencePaymentStatus: nil,
                    confidenceDate: nil,
                    imageDigest: draft.sourceKey,
                    sourceKey: draft.sourceKey,
                    schemaVersion: 2,
                    aiCandidate: item.item.categoryCandidate
                )

                do {
                    let result = try FinanceTransactionCommandService.shared.commit(draft: draftToCommit, postNotification: false)
                    if result.created {
                        // 只有本次新建的笔才有撤销权；幂等命中的是账本里已存在的交易，不能撤
                        committedIDs.append(result.transactionID)
                    } else {
                        duplicateCount += 1
                    }
                } catch {
                    failureCount += 1
                }
            }

            guard !committedIDs.isEmpty || duplicateCount > 0 else {
                errorMessage = String(localized: "保存失败，请稍后重试。")
                return
            }

            await ReceiptBookingResultStore.shared.append(result: .init(
                id: UUID(), createdAt: Date(),
                kind: .booked, reasonCode: nil,
                summaryText: summaryText(for: committedIDs.count, duplicates: duplicateCount),
                transactionID: committedIDs.first,
                additionalTransactionIDs: committedIDs.count > 1 ? Array(committedIDs.dropFirst()) : nil,
                draftID: nil,
                undoToken: committedIDs.isEmpty ? nil : UUID(),
                usedDefaultAccount: false, undoneAt: nil
            ))
            ReceiptBookingCoordinator.discardDraftFiles(draftID: draft.id)
            onFinished()
            dismiss()
            // 弹层收起动画后再广播一次：账本/账户页监听 .financeDataDidChange 即时重算汇总
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        }
    }

    private func summaryText(for committedCount: Int, duplicates: Int) -> String {
        if committedCount == 1 && duplicates == 0 {
            return String(localized: "复核入账 1 笔")
        }
        if duplicates == 0 {
            return String(localized: "复核入账 \(committedCount) 笔")
        }
        return String(localized: "复核入账 \(committedCount) 笔，\(duplicates) 笔已记过")
    }

    private func deleteDraft() {
        ReceiptBookingCoordinator.discardDraftFiles(draftID: draft.id)
        Task {
            await ReceiptBookingResultStore.shared.append(result: .init(
                id: UUID(), createdAt: Date(), kind: .rejected, reasonCode: nil,
                summaryText: String(localized: "已删除一条待复核记录"), transactionID: nil,
                additionalTransactionIDs: nil, draftID: nil, undoToken: nil,
                usedDefaultAccount: false, undoneAt: nil
            ))
        }
        onFinished()
        dismiss()
    }
}
