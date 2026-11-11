//
//  ReceiptReviewItemEditorBlock.swift
//  Holo
//
//  复核确认页 · 逐笔编辑区（2026-11-11 复核页重设计，原型即契约）：
//  单笔卡（画板①）与多笔手风琴展开块（画板②）共用同一编辑区——
//  头行（单笔：原图缩略图+记这笔开关）、转账行、金额+方向同行、票面脚注、
//  名称栏、四字段 2×2 宫格。组件不持有业务逻辑：科目建议刷新与两个弹层
//  的触发由宿主经回调注入。
//

import SwiftUI

/// 逐笔编辑状态（一图多笔；旧单笔草稿 effectiveItems 合成一条）。
/// 2026-11-11 复核页改版从 ReceiptReviewDetailView 迁出（单笔卡与多笔展开块
/// 共用编辑区组件），字段与语义零改动。
struct ReceiptReviewItemEditState: Identifiable {
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

struct ReceiptReviewItemEditorBlock: View {
    @Binding var state: ReceiptReviewItemEditState
    /// 单笔=true：卡顶渲染「44×44 原图缩略图 + 记这笔开关」头行，剔除时显示
    /// 「这笔不记，确认时将跳过」降级文案；多笔展开块=false（原图走页面入口行，
    /// 剔除=行淡出+展开块收起，不留占位行——方案 §5.3）
    var showsEvidenceThumb: Bool
    var evidenceImage: UIImage?
    var isCommitting: Bool
    var accounts: [Account]
    var projects: [FinanceProject]
    var expenseCategories: [HoloFinanceCategory]
    var incomeCategories: [HoloFinanceCategory]
    /// 方向切换联动：清空选择由组件完成，科目建议链路（宿主 refreshCategorySuggestion）经此回调
    var onDirectionChange: () -> Void
    var onTapEvidence: () -> Void
    var onTapDateChip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsEvidenceThumb {
                headRow
            }
            if state.included {
                editContent
            } else if showsEvidenceThumb {
                // 剔除降级文案只属单笔态（开关关闭）；多笔剔除=行淡出，无占位行
                Text("这笔不记，确认时将跳过")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 头行（仅单笔卡：原图角图 + 记这笔开关）

    private var headRow: some View {
        HStack {
            if let evidenceImage {
                Button(action: onTapEvidence) {
                    ZStack(alignment: .bottomTrailing) {
                        platformImage(evidenceImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        // 放大镜角标：点缩略图弹原图大图（弹层，页面位置不动）
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.holoPrimary))
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("查看原图核对"))
            }
            Spacer(minLength: 12)
            // fixedSize：压回内容宽让「记这笔 [开关]」紧排成组；开关用系统绿——
            // 主按钮已是大块主题橙，同为橙则撞色（2026-10-13 东林「不和谐」反馈）
            Toggle("记这笔", isOn: $state.included)
                .font(.footnote)
                .toggleStyle(.switch)
                .disabled(isCommitting)
                .fixedSize()
        }
    }

    // MARK: - 编辑区（顺序照原型画板①卡内：转账行→警示→金额+方向→票面脚注→名称→宫格）

    @ViewBuilder
    private var editContent: some View {
        if let kind = state.item.transferKind {
            ReceiptReviewTransferLine(
                isRedPacket: kind == HoloVisionTransferInfo.redPacketKind,
                isIncome: state.typeIsIncome,
                awaitingReceipt: state.item.transferAwaitingReceipt == true
            )
        }
        if let notes = state.item.reviewNotes, !notes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                Text(Self.reviewNotesText(notes))
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("¥").font(.title2.weight(.semibold))
                TextField("0.00", text: $state.amountText)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Picker("方向", selection: $state.typeIsIncome) {
                Text("支出").tag(false)
                Text("收入").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 108, height: 32)
            .onChange(of: state.typeIsIncome) { _, _ in
                state.selectedCategoryID = nil
                if state.typeIsIncome { state.selectedProjectID = nil }
                onDirectionChange()
            }
        }
        // 票面脚注：只在票面原文与当前输入值不一致时出现（东林 11-11 拍板②：对得上是废话）
        if let faceAmountText {
            Text("票面原文 ¥\(faceAmountText)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        // 名称=这笔账在账本里的显示名（Transaction.note），对方名唯一出现地；
        // 预填逻辑在宿主 load()；纯输入框（原型画板①：无常驻标签，placeholder「名称」兜底）
        TextField("名称", text: $state.note)
            .font(.body)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.holoSystemGray6)
            )
        Divider().overlay(Color.holoDivider)
        fieldGrid
    }

    // MARK: - 四字段 2×2 宫格（科目/账户/项目/日期，替代四整行）

    private var fieldGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            Menu {
                let categories = state.typeIsIncome ? incomeCategories : expenseCategories
                ForEach(Self.topLevelCategories(in: categories), id: \.id) { top in
                    Menu(top.name) {
                        ForEach(Self.subCategories(of: top, in: categories), id: \.id) { sub in
                            Button(sub.name) { state.selectedCategoryID = sub.id }
                        }
                    }
                }
            } label: {
                ReceiptReviewChipField(
                    icon: "tag",
                    label: "科目",
                    value: Self.categoryTitle(for: state, expense: expenseCategories, income: incomeCategories)
                )
            }
            Menu {
                ForEach(accounts, id: \.id) { account in
                    Button(account.name) { state.selectedAccountID = account.id }
                }
            } label: {
                ReceiptReviewChipField(
                    icon: "creditcard",
                    label: "账户",
                    value: Self.accountTitle(for: state, accounts: accounts)
                )
            }
            if state.typeIsIncome {
                // 收入笔不挂项目：整格置灰、无箭头、不响应点击
                ReceiptReviewChipField(
                    icon: "folder",
                    label: "项目",
                    value: String(localized: "收入不挂"),
                    dimmed: true
                )
            } else {
                Menu {
                    Button("不挂项目") { state.selectedProjectID = nil }
                    ForEach(projects, id: \.id) { project in
                        Button(project.name) { state.selectedProjectID = project.id }
                    }
                } label: {
                    ReceiptReviewChipField(
                        icon: "folder",
                        label: "项目",
                        value: Self.projectTitle(for: state, projects: projects)
                    )
                }
            }
            Button(action: onTapDateChip) {
                ReceiptReviewChipField(
                    icon: "calendar",
                    label: "日期",
                    value: Self.dateChipText(state.date)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 派生文本（紧凑行与 chip 共用同一套口径）

    /// 票面脚注文本：与当前输入值数值一致时返回 nil（不显示）
    private var faceAmountText: String? {
        guard let original = state.item.amountOriginalText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else {
            return nil
        }
        let stripped = String(original.drop(while: { $0 == "¥" || $0 == "￥" }))
        let originalValue = ReceiptBookingCoordinator.decimal(fromText: stripped)
        let currentValue = ReceiptBookingCoordinator.decimal(fromText: state.amountText)
        if let originalValue, let currentValue {
            return originalValue == currentValue ? nil : stripped
        }
        return stripped == state.amountText ? nil : stripped
    }

    /// 当前生效科目名：用户改选 > AI 解析建议
    static func categoryTitle(
        for state: ReceiptReviewItemEditState,
        expense: [HoloFinanceCategory],
        income: [HoloFinanceCategory]
    ) -> String {
        let categories = state.typeIsIncome ? income : expense
        if let selectedCategoryID = state.selectedCategoryID,
           let selected = categories.first(where: { $0.id == selectedCategoryID }) {
            return selected.name
        }
        return state.suggestedCategoryTitle.isEmpty
            ? String(localized: "正在匹配科目…")
            : state.suggestedCategoryTitle
    }

    static func accountTitle(for state: ReceiptReviewItemEditState, accounts: [Account]) -> String {
        if let selectedAccountID = state.selectedAccountID,
           let account = accounts.first(where: { $0.id == selectedAccountID }) {
            return account.name
        }
        return String(localized: "自动识别")
    }

    static func projectTitle(for state: ReceiptReviewItemEditState, projects: [FinanceProject]) -> String {
        if let selectedProjectID = state.selectedProjectID,
           let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project.name
        }
        return String(localized: "不挂项目")
    }

    static func topLevelCategories(in categories: [HoloFinanceCategory]) -> [HoloFinanceCategory] {
        categories.filter { $0.isTopLevel }
    }

    static func subCategories(
        of top: HoloFinanceCategory,
        in categories: [HoloFinanceCategory]
    ) -> [HoloFinanceCategory] {
        categories.filter { !$0.isTopLevel && $0.parentId == top.id }
    }

    /// 笔级警示文案（金额没认准等），行内与展开块同款
    static func reviewNotesText(_ notes: [String]) -> String {
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

    /// 日期 chip 文案：今年「M月d日」，跨年「yyyy年M月d日」
    static func dateChipText(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "M月d日"
        } else {
            formatter.dateFormat = "yyyy年M月d日"
        }
        return formatter.string(from: date)
    }

    private func platformImage(_ image: UIImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
