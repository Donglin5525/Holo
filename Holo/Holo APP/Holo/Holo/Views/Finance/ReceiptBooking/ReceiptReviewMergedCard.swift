//
//  ReceiptReviewMergedCard.swift
//  Holo
//
//  复核确认页 · 合并态「这一笔」编辑卡（2026-11-14 多笔合并为一笔，原型画板②）：
//  头行=方向胶囊 + 「这一笔将记为」+ 右上 44×44 原图缩略图（放大镜角标，点开弹原图）；
//  名称输入框 + 备注块（默认值与勾选联动，规则在 ReceiptReviewMerge）；
//  分隔线 + 科目/账户/项目/日期四宫格（Menu 模式复用 ReceiptReviewItemEditorBlock 同款）。
//  组件不持有业务逻辑：联动与科目建议刷新由宿主经状态与回调注入。
//

import SwiftUI

/// 合并态编辑状态：名称/备注/账户/日期带 dirty 标记——用户手动改过即冻结，
/// 不再随勾选联动重算（联动入口在宿主，规则见 ReceiptReviewMerge.sync）。
struct ReceiptReviewMergedEditState {
    var nameText = ""
    var nameDirty = false
    var remarkText = ""
    var remarkDirty = false
    /// 科目：nil = 跟随建议（金额最大笔走完整分类链）；选中后以用户选择为准
    var selectedCategoryID: UUID?
    var selectedAccountID: UUID?
    var accountDirty = false
    var selectedProjectID: UUID?
    var date = Date()
    var dateDirty = false
}

struct ReceiptReviewMergedCard: View {
    @Binding var state: ReceiptReviewMergedEditState
    /// 方向胶囊口径同紧凑行：支出橙/收入绿（转账进不了合并态，无转账口径）
    var directionIsIncome: Bool
    /// 0 笔时名称框降级为占位文案
    var includedCount: Int
    /// 科目建议标题（宿主 refreshMergedCategorySuggestion 异步刷新）
    var suggestedCategoryTitle: String
    var evidenceImage: UIImage?
    var accounts: [Account]
    var projects: [FinanceProject]
    var expenseCategories: [HoloFinanceCategory]
    var incomeCategories: [HoloFinanceCategory]
    var onTapEvidence: () -> Void
    var onTapDateChip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headRow
            nameField
            remarkBlock
            Divider().overlay(Color.holoDivider)
            fieldGrid
        }
    }

    // MARK: - 头行（方向胶囊 + 标题 + 原图缩略图）

    private var headRow: some View {
        HStack {
            HStack(spacing: 8) {
                directionPill
                Text("这一笔将记为")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let evidenceImage {
                Button(action: onTapEvidence) {
                    ZStack(alignment: .bottomTrailing) {
                        platformImage(evidenceImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        // 放大镜角标：样式照 ReceiptReviewItemEditorBlock.headRow（点开弹原图）
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
        }
    }

    private var directionPill: some View {
        Text(directionIsIncome ? String(localized: "收") : String(localized: "支"))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
            .fixedSize()
    }

    private var tint: Color { directionIsIncome ? .green : .orange }

    // MARK: - 名称（44pt 灰底圆角，同逐笔编辑块名称栏）

    private var nameField: some View {
        TextField(
            includedCount == 0 ? String(localized: "先勾选要合并的账") : String(localized: "名称"),
            text: nameBinding
        )
        .font(.body)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.holoSystemGray6)
        )
    }

    /// 用户敲键才置 dirty；宿主联动写 state 不经此 binding，自动改写不会被误判为手改
    private var nameBinding: Binding<String> {
        Binding(
            get: { state.nameText },
            set: {
                state.nameText = $0
                state.nameDirty = true
            }
        )
    }

    // MARK: - 备注（灰底圆角框：小标签 + 可编辑多行文本，可清空）

    private var remarkBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备注")
                .font(.caption2)
                .foregroundColor(.holoTextSecondary)
            TextField("备注", text: remarkBinding, axis: .vertical)
                .font(.caption)
                .foregroundStyle(Color.holoTextPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.holoSystemGray6)
        )
    }

    private var remarkBinding: Binding<String> {
        Binding(
            get: { state.remarkText },
            set: {
                state.remarkText = $0
                state.remarkDirty = true
            }
        )
    }

    // MARK: - 四字段 2×2 宫格（科目/账户/项目/日期，作用于合并记录整体）

    private var fieldGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            Menu {
                let categories = directionIsIncome ? incomeCategories : expenseCategories
                ForEach(ReceiptReviewItemEditorBlock.topLevelCategories(in: categories), id: \.id) { top in
                    Menu(top.name) {
                        ForEach(ReceiptReviewItemEditorBlock.subCategories(of: top, in: categories), id: \.id) { sub in
                            Button(sub.name) { state.selectedCategoryID = sub.id }
                        }
                    }
                }
            } label: {
                ReceiptReviewChipField(
                    icon: "tag",
                    label: "科目",
                    value: categoryTitle
                )
            }
            Menu {
                ForEach(accounts, id: \.id) { account in
                    Button(account.name) {
                        state.selectedAccountID = account.id
                        state.accountDirty = true
                    }
                }
            } label: {
                ReceiptReviewChipField(
                    icon: "creditcard",
                    label: "账户",
                    value: accountTitle
                )
            }
            if directionIsIncome {
                // 收入不挂项目：整格置灰、无箭头、不响应点击（同逐笔编辑块）
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
                        value: projectTitle
                    )
                }
            }
            Button(action: onTapDateChip) {
                ReceiptReviewChipField(
                    icon: "calendar",
                    label: "日期",
                    value: ReceiptReviewItemEditorBlock.dateChipText(state.date)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 派生文本（口径同 ReceiptReviewItemEditorBlock）

    /// 当前生效科目名：用户改选 > 建议标题（空=正在匹配）
    private var categoryTitle: String {
        let categories = directionIsIncome ? incomeCategories : expenseCategories
        if let selectedCategoryID = state.selectedCategoryID,
           let selected = categories.first(where: { $0.id == selectedCategoryID }) {
            return selected.name
        }
        return suggestedCategoryTitle.isEmpty
            ? String(localized: "正在匹配科目…")
            : suggestedCategoryTitle
    }

    private var accountTitle: String {
        if let selectedAccountID = state.selectedAccountID,
           let account = accounts.first(where: { $0.id == selectedAccountID }) {
            return account.name
        }
        return String(localized: "自动识别")
    }

    private var projectTitle: String {
        if let selectedProjectID = state.selectedProjectID,
           let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project.name
        }
        return String(localized: "不挂项目")
    }

    private func platformImage(_ image: UIImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
