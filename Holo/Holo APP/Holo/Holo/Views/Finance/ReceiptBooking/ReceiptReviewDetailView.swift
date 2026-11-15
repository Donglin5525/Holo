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
//  2026-11-11 复核页重设计（原型即契约，docs/design-prototypes/receipt-review-redesign-prototype.html）：
//  「看/改分离」——单笔一张卡全字段一屏（四字段 2×2 宫格、日期 chip+弹层、原图 44×44 卡角小图）；
//  多笔卡头汇总条（笔数+合计大字）+ 52pt 紧凑行手风琴展开细改（一次只展开一笔）。
//  编辑区/紧凑行/弹层拆出独立文件；确认落账链路零改动。
//  2026-11-14 多笔合并为一笔（原型即契约 receipt-review-merge-prototype.html）：
//  多笔列表卡底部新增「合并记为一笔 / 分开记」切换；合并态清单收成单行勾选池，
//  下方长出「这一笔」编辑卡（ReceiptReviewMergedCard），确认只落一条
//  （规则内核在 ReceiptReviewMerge.swift）；分开记全链路行为不变。
//

import SwiftUI

#if canImport(UIKit)
/// iOS 上 Category 与系统类型同名冲突，用模块限定 Holo.Category；macOS 模块名是 HoloMac，
/// 统一经此别名引用（两端都指向本 App 的记账分类实体；本文件仅主 App 与 Mac target 编译）
typealias HoloFinanceCategory = Holo.Category
#else
typealias HoloFinanceCategory = Category
#endif

struct ReceiptReviewDetailView: View {
    let draft: ReceiptBookingResultStore.StoredDraft
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 逐笔编辑状态（2026-11-11 迁出到 ReceiptReviewItemEditorBlock.swift，单笔卡与多笔展开块共用）
    @State private var itemStates: [ReceiptReviewItemEditState] = []
    @State private var accounts: [Account] = []
    @State private var projects: [FinanceProject] = []
    @State private var expenseCategories: [HoloFinanceCategory] = []
    @State private var incomeCategories: [HoloFinanceCategory] = []
    @State private var evidenceImage: UIImage?
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    // 2026-11-11 重设计新增 UI 态：多笔手风琴（一次只展开一笔）、原图弹层、日期弹层锚点
    @State private var expandedItemID: String?
    @State private var showEvidenceSheet = false
    @State private var activeDateItemID: String?

    // 2026-11-14 多笔合并为一笔：分开记/合并记切换、合并态「这一笔」卡状态
    @State private var mergeMode = false
    @State private var mergedState = ReceiptReviewMergedEditState()
    @State private var mergedSuggestedCategoryTitle = ""
    @State private var mergedSuggestedCategoryTask: Task<Void, Never>?
    @State private var mergedDatePickerActive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                metaLine
                if let pageReasonText {
                    Text(pageReasonText)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if itemStates.count == 1 {
                    // 单笔：一张卡全字段一屏（编辑区带「原图角图 + 记这笔」头行）
                    ForEach($itemStates) { $state in
                        card {
                            editorBlock(for: $state, showsEvidenceThumb: true)
                        }
                    }
                } else {
                    multiItemSection
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.holoToolError)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.xl)
        }
        .background(
            Color.holoSecondaryGroupedBackground
                .ignoresSafeArea()
        )
        .onTapGesture(perform: dismissKeyboard)
        .navigationTitle(itemStates.count > 1 ? Text("确认这几笔账") : Text("确认这笔账"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            actionButtons
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
        }
        .confirmationDialog("删除这条待复核记录？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteDraft)
            Button("取消", role: .cancel) {}
        } message: {
            Text("草稿和暂存的证据图会被删除，且不会记账。")
        }
        .sheet(isPresented: $showEvidenceSheet) {
            ReceiptReviewEvidenceSheet(image: evidenceImage)
        }
        .sheet(isPresented: dateSheetPresentation) {
            ReceiptReviewDatePickerSheet(date: activeDateBinding ?? .constant(Date()))
        }
        .onAppear(perform: load)
        .onDisappear {
            for index in itemStates.indices {
                itemStates[index].suggestedCategoryTask?.cancel()
            }
            mergedSuggestedCategoryTask?.cancel()
        }
    }

    // MARK: - 页面骨架

    /// 信息行：识别时间必显（2026-09-23 起旧草案一眼可辨）。
    /// 多笔合计 2026-11-11 升级为列表卡头部汇总条，meta 行只留左侧（原型画板②）
    private var metaLine: some View {
        Text("识别于 \(ReceiptRecognizedTimeText.text(for: draft.createdAt))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 多笔：原图入口行（36pt）+ 一张列表卡（汇总条 + 紧凑行 + 展开块 + 模式切换行）；
    /// 合并态原图入口并进「这一笔」卡右上角小图，列表卡下方长出「这一笔」卡
    @ViewBuilder
    private var multiItemSection: some View {
        if evidenceImage != nil, !mergeMode {
            evidenceEntryRow
        }
        card {
            VStack(spacing: 0) {
                summaryHeader
                Divider().overlay(Color.holoDivider)
                ForEach($itemStates) { $state in
                    compactItemRow(for: $state)
                    if state.id != itemStates.last?.id {
                        Divider().overlay(Color.holoDivider)
                    }
                }
                mergeModeRow
            }
        }
        if mergeMode {
            card {
                ReceiptReviewMergedCard(
                    state: $mergedState,
                    directionIsIncome: includedStates.first?.typeIsIncome ?? false,
                    includedCount: includedStates.count,
                    suggestedCategoryTitle: mergedSuggestedCategoryTitle,
                    evidenceImage: evidenceImage,
                    accounts: accounts,
                    projects: projects,
                    expenseCategories: expenseCategories,
                    incomeCategories: incomeCategories,
                    onTapEvidence: { showEvidenceSheet = true },
                    onTapDateChip: { mergedDatePickerActive = true }
                )
            }
        }
    }

    /// 模式切换行（清单卡底部，上方细分隔线）：分开记=橙色「合并记为一笔」，
    /// 合并态=灰色「分开记」；守卫拦下时置灰并在行上方给一行原因说明
    private var mergeModeRow: some View {
        VStack(spacing: 0) {
            if let mergeGuardHint {
                Text(mergeGuardHint.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 9)
            }
            Divider().overlay(Color.holoDivider)
            Button {
                guard mergeGuardHint == nil else { return }
                withAnimation(HoloAnimation.standard) {
                    mergeMode.toggle()
                    // 切模式收起所有手风琴展开块；勾选状态保留
                    expandedItemID = nil
                    if mergeMode {
                        ReceiptReviewMerge.sync(&mergedState, with: includedStates)
                        refreshMergedCategorySuggestion()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mergeMode ? "arrow.turn.up.left" : "arrow.triangle.merge")
                        .font(.system(size: 14))
                    Text(mergeMode ? "分开记" : "合并记为一笔")
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .foregroundStyle(modeRowTint)
            }
            .buttonStyle(.plain)
            .disabled(mergeGuardHint != nil)
        }
    }

    private var modeRowTint: Color {
        if mergeGuardHint != nil { return Color.holoTextPlaceholder }
        return mergeMode ? Color.holoTextSecondary : Color.holoPrimary
    }

    /// 合并入口守卫：勾选笔方向混排/含转账时不可进入合并态（规则在 ReceiptReviewMerge）
    private var mergeGuardHint: ReceiptReviewMerge.GuardHint? {
        ReceiptReviewMerge.guardHint(includedStates)
    }

    /// 原图入口行：点开弹层看大图，看完关掉页面位置不动（不再页面内嵌撑开一大块）
    private var evidenceEntryRow: some View {
        Button {
            showEvidenceSheet = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "photo")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text("查看原图核对")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize()
                Text("仅在本机暂存，确认或删除后自动清理")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.holoCardBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 卡头汇总条（东林 11-11 拍板⑦：合计是关键信息，从 meta 小灰字升级至此）：
    /// 左「N 笔待确认」13pt semibold 次级色，右合计 24pt rounded 大字，勾选实时联动；
    /// 全剔除时金额置灰。收支方向不一致时不给合计（加总无意义，沿用 uniformTotalText 口径）。
    /// 合并态计数变「N 笔 · 合成 1 笔」（"1 笔"主题橙加粗），0 笔时占位提示
    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            if mergeMode {
                mergedCountTitle
            } else {
                Text("\(includedStates.count) 笔待确认")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsSummaryTotal {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("¥")
                        .font(.system(size: 15, weight: .bold))
                    Text(summaryTotalText)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(includedStates.isEmpty ? Color.holoTextPlaceholder : Color.holoTextPrimary)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 合并态卡头计数：「N 笔 · 合成 1 笔」，"1 笔"主题橙加粗；0 笔占位
    @ViewBuilder
    private var mergedCountTitle: some View {
        if includedStates.isEmpty {
            Text("先勾选要合并的账")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            Text("\(includedStates.count) 笔 · 合成 ")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            + Text("1 笔")
                .font(.footnote.weight(.heavy))
                .foregroundStyle(Color.holoPrimary)
        }
    }

    private var showsSummaryTotal: Bool {
        uniformTotalText != nil || includedStates.isEmpty
    }

    private var summaryTotalText: String {
        if let total = uniformTotalText { return total }
        return ReceiptBookingCoordinator.formatAmount(Decimal(0))
    }

    /// 单笔紧凑行 + 手风琴展开块（一次只展开一笔，展开块无头行/缩略图）；
    /// 合并态收成单行勾选池（不展开），勾选变化联动「这一笔」卡默认值
    private func compactItemRow(for state: Binding<ReceiptReviewItemEditState>) -> some View {
        let itemID = state.wrappedValue.id
        return VStack(spacing: 0) {
            ReceiptReviewCompactRow(
                state: state,
                accounts: accounts,
                projects: projects,
                expenseCategories: expenseCategories,
                incomeCategories: incomeCategories,
                isExpanded: expandedItemID == itemID,
                mergeMode: mergeMode,
                onToggleIncluded: {
                    withAnimation(HoloAnimation.standard) {
                        state.wrappedValue.included.toggle()
                        // 剔除=整行淡出（方案 §5.3）：该笔展开块随之收起，不留占位行
                        if !state.wrappedValue.included, expandedItemID == itemID {
                            expandedItemID = nil
                        }
                    }
                    if mergeMode {
                        // 勾选四联动：用户没改过的名称/备注/账户/日期跟随勾选重算
                        ReceiptReviewMerge.sync(&mergedState, with: includedStates)
                        refreshMergedCategorySuggestion()
                    }
                },
                onToggleExpanded: {
                    // 剔除行不展开（无编辑内容可改，恢复勾选后再展开）；
                    // 合并态清单只做勾选池，细改集中在「这一笔」卡
                    guard !mergeMode, state.wrappedValue.included else { return }
                    withAnimation(HoloAnimation.standard) {
                        expandedItemID = expandedItemID == itemID ? nil : itemID
                    }
                }
            )
            if expandedItemID == itemID {
                editorBlock(for: state, showsEvidenceThumb: false)
                    // 缩进仅作层级暗示：35pt 会挤掉宫格值宽（「不挂项目」被截，判读 P0），收窄到 12
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
    }

    /// 逐笔编辑区（单笔卡与多笔展开块共用；回调把业务联动留在宿主）
    private func editorBlock(
        for state: Binding<ReceiptReviewItemEditState>,
        showsEvidenceThumb: Bool
    ) -> some View {
        ReceiptReviewItemEditorBlock(
            state: state,
            showsEvidenceThumb: showsEvidenceThumb,
            evidenceImage: evidenceImage,
            isCommitting: isCommitting,
            accounts: accounts,
            projects: projects,
            expenseCategories: expenseCategories,
            incomeCategories: incomeCategories,
            onDirectionChange: {
                refreshCategorySuggestion(index: itemIndex(of: state.wrappedValue.id))
            },
            onTapEvidence: { showEvidenceSheet = true },
            onTapDateChip: { activeDateItemID = state.wrappedValue.id }
        )
    }

    /// 日期弹层锚定：itemKey 锚到对应笔的 date（弹层内改即改这笔）；
    /// 合并态锚到「这一笔」卡的合并日期（改过即视为手动指定，不再随勾选联动）
    private var dateSheetPresentation: Binding<Bool> {
        Binding(
            get: { activeDateItemID != nil || mergedDatePickerActive },
            set: {
                if !$0 {
                    activeDateItemID = nil
                    mergedDatePickerActive = false
                }
            }
        )
    }

    private var activeDateBinding: Binding<Date>? {
        if mergedDatePickerActive {
            return Binding(
                get: { mergedState.date },
                set: {
                    mergedState.date = $0
                    mergedState.dateDirty = true
                }
            )
        }
        guard let id = activeDateItemID,
              let index = itemStates.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: { itemStates[index].date },
            set: { itemStates[index].date = $0 }
        )
    }

    /// 点内容区空白收起金额/名称键盘（照 AddTransactionSheet 的收键盘手法）
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.sendAction(#selector(NSResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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

            // 低频操作收一行（2026-10-13 原型画板②：三按钮竖排≈250pt 吃掉小屏首屏）
            HStack(spacing: 22) {
                Button {
                    dismiss()
                } label: {
                    Text("稍后处理")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(isCommitting)
                Text("·").foregroundStyle(.tertiary)
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Text("删除草稿")
                        .font(.subheadline)
                        .foregroundStyle(Color.holoToolError)
                }
                .disabled(isCommitting)
            }
            .frame(maxWidth: .infinity)
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

    private var includedStates: [ReceiptReviewItemEditState] {
        itemStates.filter(\.included)
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
        // 全剔除（2026-11-11 拍板）：不再是「确认记 0 笔」怪文案，明确指向勾选动作
        if count == 0 { return String(localized: "先勾选要记的账") }
        let total = uniformTotalText
        if count == 1 {
            return total.map { String(localized: "确认记账 ¥\($0)") } ?? String(localized: "确认记账")
        }
        // 合并态：勾选再多笔也只落一条（方向已在入口守卫统一，total 必非空）
        if mergeMode, let total {
            return String(localized: "确认记 1 笔 · ¥\(total)")
        }
        return total.map { String(localized: "确认记 \(count) 笔 · ¥\($0)") } ?? String(localized: "确认记 \(count) 笔")
    }

    private var canCommit: Bool {
        let included = includedStates
        guard !included.isEmpty else { return false }
        let amountsValid = included.allSatisfy { state in
            (ReceiptBookingCoordinator.decimal(fromText: state.amountText) ?? 0) > 0
        }
        // 合并态：账户以「这一笔」卡为准（逐笔账户仅作默认值来源）
        if mergeMode {
            return amountsValid && mergedState.selectedAccountID != nil
        }
        return amountsValid && included.allSatisfy { $0.selectedAccountID != nil }
    }

    private func itemIndex(of itemKey: String) -> Int? {
        itemStates.firstIndex { $0.id == itemKey }
    }

    /// 页面级复核原因：只在有具体原因时显示一行（2026-10-13 原型画板②：
    /// 「这笔账需要你确认。」兜底文案每张卡都有=零信息，不再展示）；
    /// 笔级原因（金额没认准等）由各笔的 reviewNotes 行承载。
    /// 2026-11-11 拍板：转账笔「请核对方向和对方。」不再显示——转账行方向胶囊已说清方向，
    /// 对方名只在名称栏出现一次；多笔提示压成一句「勾掉不想记的，一次入账。」
    private var pageReasonText: String? {
        guard let first = draft.reasons.first, let reason = ReceiptBookingReason(rawValue: first) else {
            return nil
        }
        switch reason {
        case .reviewMultipleTransactions:
            // 合并态换口径：勾掉的笔不记，其余合成一笔（原型画板②）
            return mergeMode
                ? String(localized: "勾掉的笔不记，其余合成一笔。")
                : String(localized: "勾掉不想记的，一次入账。")
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
        case .reviewTransferConfirm: return nil
        default: return nil
        }
    }

    // MARK: - 数据

    private func load() {
        let repo = FinanceRepository.shared
        accounts = repo.getAccounts(includeArchived: false)
        projects = FinanceProjectRepository.shared.activeProjects()

        itemStates = draft.effectiveItems.enumerated().map { itemIndex, item in
            var state = ReceiptReviewItemEditState(
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
            // 名称预填：转账/红包用该笔自己的对方名（一图多笔各笔对方不同），
            // 其余商户名优先（它就是这笔账在账本里的名字），无商户回退 AI 备注原文
            let merchant = draft.merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let counterparty = item.transferCounterparty, !counterparty.isEmpty {
                state.note = counterparty
            } else {
                state.note = merchant.isEmpty ? (item.note ?? "") : merchant
            }
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
        // 本机暂存的复核证据图（确认/删除后随之删除）；降采样加载防整幅原图解码
        if let url = ReceiptBookingResultStore.evidenceImageURL(for: draft.id) {
            Task { @MainActor in
                #if canImport(UIKit)
                evidenceImage = await ImageDownsampler.image(at: url)
                #else
                if let data = try? Data(contentsOf: url) {
                    evidenceImage = UIImage(data: data)
                }
                #endif
            }
        }
    }

    /// 科目建议：逐笔走完整分类链（学习映射→标准→自定义→别名→语义）
    private func refreshCategorySuggestion(index: Int?) {
        guard let index else { return }
        let state = itemStates[index]
        state.suggestedCategoryTask?.cancel()
        let type: TransactionType = state.typeIsIncome ? .income : .expense
        let task = Task { @MainActor in
            let category = try? await FinanceTransactionDraftResolver.shared.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: state.item.categoryCandidate,
                normalizedCategoryCandidate: state.item.normalizedCategoryCandidate,
                semanticCategoryHint: state.item.semanticCategoryHint,
                note: state.note.isEmpty ? (state.item.note ?? draft.merchant ?? "") : state.note,
                type: type,
                transferKind: state.item.transferKind
            )
            guard !Task.isCancelled, let index = itemIndex(of: state.id) else { return }
            itemStates[index].suggestedCategoryTitle = category?.name ?? String(localized: "待分类")
        }
        itemStates[index].suggestedCategoryTask = task
        itemStates[index].suggestedCategoryTitle = ""
    }

    // MARK: - 确认（走公共 CommandService，§25.2；逐笔提交整批完成；
    //          合并态整单只落一条，2026-11-14 多笔合并为一笔）

    private func confirm() {
        let included = includedStates
        guard !included.isEmpty else { return }
        if mergeMode {
            confirmMerged(included)
            return
        }
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
                let category: HoloFinanceCategory?
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
                            type: item.typeIsIncome ? .income : .expense,
                            transferKind: item.item.transferKind
                        )
                    } catch {
                        category = nil
                    }
                }
                let finalCategory: HoloFinanceCategory = category ?? repo.ensurePendingCategory(type: item.typeIsIncome ? .income : .expense)
                let names = repo.resolveCategoryNames(from: finalCategory)
                // 分类学习写回：用户在确认页改选过科目才学，AI 建议被直接确认不学；
                // 用户所选科目已失效（解析落空）时目标不可信，同样不学
                if item.selectedCategoryID != nil, category != nil {
                    ReceiptBookingCoordinator.recordCategoryLearningIfNeeded(
                        userSelectedCategoryID: item.selectedCategoryID,
                        categoryCandidate: item.item.categoryCandidate,
                        merchant: draft.merchant,
                        typeIsIncome: item.typeIsIncome,
                        targetPrimary: names.primary,
                        targetSub: names.sub ?? names.primary
                    )
                }
                let accountName = repo.findAccount(by: accountID)?.name ?? ""

                let draftToCommit = ResolvedTransactionDraft(
                    itemKey: item.id,
                    amount: amount,
                    typeIsIncome: item.typeIsIncome,
                    date: item.date,
                    dateInferredFromCapture: item.item.dateText == nil,
                    // 名称即账本显示名：用户清空=明确不要名字（账本回退显示科目名）
                    note: item.note.isEmpty ? nil : item.note,
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
                        // 产品埋点：识图复核确认入账成功（此路径不经过 FinanceRepository 的手动/聊天汇聚点；
                        // 一图多笔逐笔上报，与字典「记账一笔落库成功」口径一致；不收金额内容）
                        HoloProductAnalytics.shared.track(.billCreated, ["source": "receipt"])
                        // 一图多笔：每笔都挂证据票根（开关关时方法内直接返回；
                        // await 保证读证据文件先于循环后的草案删除）
                        await FinanceTransactionCommandService.shared.archiveEvidenceIfNeeded(
                            draftID: draft.id,
                            transactionID: result.transactionID
                        )
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

    /// 合并确认（2026-11-14 多笔合并为一笔）：勾选笔合成一条 ResolvedTransactionDraft，
    /// 落库 1 条、票根归档与 billCreated 埋点各一次；重复确认同草稿由
    /// 幂等键（sourceKey + mergedItemKey）拦截不重复入账
    private func confirmMerged(_ included: [ReceiptReviewItemEditState]) {
        guard let accountID = mergedState.selectedAccountID else { return }
        isCommitting = true
        errorMessage = nil

        Task { @MainActor in
            defer { isCommitting = false }
            let repo = FinanceRepository.shared
            let resolver = FinanceTransactionDraftResolver.shared

            // 科目建议：用户没改选时用金额最大笔的候选链重解析（确认时重跑，不信任 chip 缓存标题）
            var suggestedCategory: HoloFinanceCategory?
            if mergedState.selectedCategoryID == nil,
               let largest = ReceiptReviewMerge.largestAmountItem(included) {
                suggestedCategory = try? await resolver.matchCategory(
                    primaryCategory: nil,
                    subCategory: nil,
                    categoryCandidate: largest.item.categoryCandidate,
                    normalizedCategoryCandidate: largest.item.normalizedCategoryCandidate,
                    semanticCategoryHint: largest.item.semanticCategoryHint,
                    note: largest.note.isEmpty ? (largest.item.note ?? draft.merchant ?? "") : largest.note,
                    type: largest.typeIsIncome ? .income : .expense,
                    transferKind: largest.item.transferKind
                )
            }

            let draftToCommit = ReceiptReviewMerge.buildDraft(
                included: included,
                name: mergedState.nameText,
                remark: mergedState.remarkText,
                date: mergedState.date,
                selectedCategoryID: mergedState.selectedCategoryID,
                suggestedCategory: suggestedCategory,
                accountID: accountID,
                projectID: mergedState.selectedProjectID,
                projectName: projects.first(where: { $0.id == mergedState.selectedProjectID })?.name,
                sourceKey: draft.sourceKey,
                paymentStatusOriginalText: draft.paymentStatusOriginalText,
                repo: repo
            )

            var committedID: UUID?
            var duplicateCount = 0
            do {
                let result = try FinanceTransactionCommandService.shared.commit(
                    draft: draftToCommit, postNotification: false
                )
                if result.created {
                    committedID = result.transactionID
                    // 合并只落一条：埋点与票根归档都只跑一次（开关关时归档方法内直接返回）
                    HoloProductAnalytics.shared.track(.billCreated, ["source": "receipt"])
                    await FinanceTransactionCommandService.shared.archiveEvidenceIfNeeded(
                        draftID: draft.id,
                        transactionID: result.transactionID
                    )
                } else {
                    duplicateCount = 1
                }
            } catch {
                errorMessage = String(localized: "保存失败，请稍后重试。")
                return
            }

            await ReceiptBookingResultStore.shared.append(result: .init(
                id: UUID(), createdAt: Date(),
                kind: .booked, reasonCode: nil,
                summaryText: committedID != nil
                    ? String(localized: "复核入账 1 笔 · \(included.count) 笔合并")
                    : summaryText(for: 0, duplicates: 1),
                transactionID: committedID,
                additionalTransactionIDs: nil,
                draftID: nil,
                undoToken: committedID == nil ? nil : UUID(),
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

    /// 合并态科目建议：金额最大勾选笔走完整分类链（与逐笔 refreshCategorySuggestion 同口径）；
    /// 勾选变化/切入合并态时刷新，用户改选后仅作 chip 兜底展示（确认时以改选为准）
    private func refreshMergedCategorySuggestion() {
        mergedSuggestedCategoryTask?.cancel()
        guard let largest = ReceiptReviewMerge.largestAmountItem(includedStates) else {
            mergedSuggestedCategoryTitle = ""
            return
        }
        let type: TransactionType = largest.typeIsIncome ? .income : .expense
        let task = Task { @MainActor in
            let category = try? await FinanceTransactionDraftResolver.shared.matchCategory(
                primaryCategory: nil,
                subCategory: nil,
                categoryCandidate: largest.item.categoryCandidate,
                normalizedCategoryCandidate: largest.item.normalizedCategoryCandidate,
                semanticCategoryHint: largest.item.semanticCategoryHint,
                note: largest.note.isEmpty ? (largest.item.note ?? draft.merchant ?? "") : largest.note,
                type: type,
                transferKind: largest.item.transferKind
            )
            guard !Task.isCancelled else { return }
            mergedSuggestedCategoryTitle = category?.name ?? String(localized: "待分类")
        }
        mergedSuggestedCategoryTask = task
        mergedSuggestedCategoryTitle = ""
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
